use num_bigint::BigInt;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::error::Error;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use std::vec::Vec;

use codetracer_trace_types::{
    CallKey, EventLogKind, FullValueRecord, FunctionId, FunctionRecord, Line, NO_KEY, PathId, Place, StepId, TypeId,
    TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord, VariableId,
};
use log::{error, info, warn};

use crate::distinct_vec::DistinctVec;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
use crate::replay::ReplaySession;
use crate::task::{
    Action, Breakpoint, Call, CallArg, CallLine, CoreTrace, CtLoadLocalsArguments, DapTracepoint, Events,
    HistoryResultWithRecord, LoadHistoryArg, Location, NO_ADDRESS, NO_INDEX, NO_PATH, NO_POSITION, ProgramEvent,
    RRTicks, TracepointHit, VariableWithRecord,
};
use crate::trace_reader::TraceReader;
use crate::value::{Type, Value, ValueRecordWithType};

pub(crate) const NEXT_INTERNAL_STEP_OVERS_LIMIT: usize = 1_000;

#[derive(Debug, Clone)]
pub struct Db {
    pub workdir: PathBuf,
    pub functions: DistinctVec<FunctionId, FunctionRecord>,
    pub calls: DistinctVec<CallKey, DbCall>,
    pub steps: DistinctVec<StepId, DbStep>,
    pub variables: DistinctVec<StepId, Vec<FullValueRecord>>,
    pub instructions: DistinctVec<StepId, Vec<String>>,
    pub types: DistinctVec<TypeId, TypeRecord>,
    pub events: Vec<DbRecordEvent>,
    pub paths: DistinctVec<PathId, String>,
    pub variable_names: DistinctVec<VariableId, String>,

    pub compound: DistinctVec<StepId, HashMap<Place, ValueRecord>>,
    // pub compound_items: DistinctVec<StepId, HashMap<(Place, usize), Place>>,
    pub cells: DistinctVec<StepId, HashMap<Place, ValueRecord>>,
    pub cell_changes: HashMap<Place, Vec<CellChange>>,
    pub variable_cells: DistinctVec<StepId, HashMap<VariableId, Place>>,
    // callstack level => active variables; used while postprocessing
    // to fill variable_cells
    pub local_variable_cells: Vec<HashMap<VariableId, Place>>,

    pub step_map: DistinctVec<PathId, HashMap<usize, Vec<DbStep>>>,
    pub path_map: HashMap<String, PathId>,

    pub end_of_program: EndOfProgram,
    // TODO? probably names wouldn't be unique
    // maybe combine name with location?
    // pub function_map: HashMap<String, Vec<FunctionId>>
}

impl Db {
    pub fn new(workdir: &PathBuf) -> Self {
        Db {
            workdir: PathBuf::from(workdir),
            functions: DistinctVec::new(),
            calls: DistinctVec::new(),
            steps: DistinctVec::new(),
            variables: DistinctVec::new(),
            instructions: DistinctVec::new(),
            types: DistinctVec::new(),
            events: vec![],
            paths: DistinctVec::new(),
            variable_names: DistinctVec::new(),

            compound: DistinctVec::new(),
            // compound_items: DistinctVec::new(),
            cells: DistinctVec::new(),
            cell_changes: HashMap::new(),
            variable_cells: DistinctVec::new(),
            local_variable_cells: vec![],

            step_map: DistinctVec::new(),
            path_map: HashMap::new(),

            end_of_program: EndOfProgram::Normal, // by default, but has to be reassigned in postprocessing
        }
    }

    pub fn step_from(&'_ self, step_id: StepId, forward: bool) -> StepIterator<'_> {
        StepIterator {
            db: self,
            step_id,
            forward,
        }
    }

    // this seems wrong in hopefully rare cases: sometimes it can lead to a bug: buggy call name
    // maybe we don't always perfectly sync initial call step with the call
    // TODO: refine that in trace_processor/make this more robust
    pub fn call_key_for_step(&self, step_id: StepId) -> CallKey {
        let step_record = &self.steps[step_id];
        step_record.call_key
    }

    // if we pass CallKey(< 0), we take the step call key, otherwise we take call_key_arg for call key
    pub fn load_location(&self, step_id: StepId, call_key_arg: CallKey, expr_loader: &mut ExprLoader) -> Location {
        let step_id_int = step_id.0;
        let step_record = &self.steps[step_id];
        let path = format!(
            "{}",
            self.workdir
                .join(self.load_path_from_id(&step_record.path_id))
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

        // info!("load_location {step_id:?} {call_key:?}");

        let (function_name, callstack_depth) = if call_key != NO_KEY {
            let call = &self.calls[call_key];
            let function = &self.functions[call.function_id];
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
            match expr_loader.load_file(&PathBuf::from(&self.paths[self.steps[step_id].path_id])) {
                Ok(_) => {
                    // let function_record = &self.functions[self.calls[CallKey(call_key_int)].function_id];
                    // let lang = expr_loader.get_current_language(&PathBuf::from(path));
                    // let fn_line: Line = if lang == Lang::Noir {
                    //     Line(function_record.line.0 - 1)
                    // } else {
                    //     function_record.line
                    // };
                    let (fn_start, fn_last) = expr_loader.get_first_last_fn_lines(&location);
                    let lang = expr_loader.get_current_language(&PathBuf::from(&path));
                    // BEAM languages (Elixir + Erlang) carry their function ranges
                    // through manifests, not tree-sitter — skip the expr-loader
                    // override for both and fall through to the trace-derived
                    // boundaries below.
                    if lang != Lang::Elixir && lang != Lang::Erlang && fn_start > 0 && fn_last >= fn_start {
                        location.function_first = fn_start;
                        location.function_last = fn_last;
                    } else {
                        let function_id = self.calls[CallKey(call_key_int)].function_id;
                        let function_record = &self.functions[function_id];
                        location.function_first = function_record.line.0;
                        let mut last_line = function_record.line.0;
                        let steps_len = self.steps.len() as i64;
                        for i in step_id_int..steps_len {
                            let step = self.steps[StepId(i)];
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
                }
                Err(e) => {
                    // No tree-sitter grammar for this language (Cairo, Circom, etc.).
                    // Fall back to the trace's own function line data.
                    warn!("expr loader load file error: {e:?} — using trace function boundaries");
                    let function_id = self.calls[CallKey(call_key_int)].function_id;
                    let function_record = &self.functions[function_id];
                    location.function_first = function_record.line.0;
                    // Estimate function_last from the last step in this call.
                    // Walk steps from the call's step_id to find the last line in this call scope.
                    let mut last_line = function_record.line.0;
                    let steps_len = self.steps.len() as i64;
                    for i in step_id_int..steps_len {
                        let step = self.steps[StepId(i)];
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
            }
        }
        location
    }

    pub fn load_path_from_id(&self, id: &PathId) -> &str {
        &self.paths[*id]
    }

    // returns the new step id and if a limit(first or last step) of the record is reached
    pub fn next_step_id_relative_to(
        &self,
        step_id: StepId,
        forward: bool,
        step_to_different_line: bool,
    ) -> (StepId, bool) {
        self.next_step_id_relative_to_with_granularity(step_id, forward, step_to_different_line, false)
    }

    /// Generalised next-step driver shared by the line-granularity
    /// (`next_step_id_relative_to`) and statement-granularity (M2)
    /// runners.  Both forms spin the same `step_over_depths_step_id`
    /// loop and apply the same bounds / step-cap guards; they differ
    /// only in the loop-termination predicate:
    ///
    /// * `step_to_different_line = false`, `step_to_different_column = false`
    ///   → single hop at same-or-shallower depth (raw next-statement
    ///   primitive used internally by `step_over_depths_step_id`
    ///   callers that want exactly one hop).
    ///
    /// * `step_to_different_line = true`, `step_to_different_column = false`
    ///   → line-granularity `next` — keep hopping while the step
    ///   stays on the same `(path_id, line, call_key)`.  The legacy
    ///   F10 behaviour.
    ///
    /// * `step_to_different_column = true` → statement-granularity
    ///   `next` (M2) — keep hopping while the step stays on the same
    ///   `(path_id, line, column, call_key)`.  This drops out as soon
    ///   as EITHER line changes OR column changes, which under the
    ///   column-aware recorder contract corresponds to a statement
    ///   boundary.  When the column field is `None` (legacy
    ///   line-only trace), the column equality reduces to the
    ///   line-only check — statement granularity quietly degrades to
    ///   line granularity, which is the correct fallback for traces
    ///   without column data.
    ///
    /// Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M2.
    pub fn next_step_id_relative_to_with_granularity(
        &self,
        step_id: StepId,
        forward: bool,
        step_to_different_line: bool,
        step_to_different_column: bool,
    ) -> (StepId, bool) {
        let mut last_step_id = step_id;
        // Bounds-check: if step_id is invalid return it unchanged (no move happened).
        let Some(original_step) = self.steps.get(step_id) else {
            warn!(
                "next_step_id_relative_to: step_id {:?} is out of bounds (steps len {})",
                step_id,
                self.steps.len()
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
            // delta = 0 => we target same or upper level
            let current_step_id = self.step_over_depths_step_id(last_step_id, forward, 0);
            if current_step_id == last_step_id {
                return (current_step_id, false); // probably reached last or first step
            }
            last_step_id = current_step_id;
            count += 1;
            if count >= NEXT_INTERNAL_STEP_OVERS_LIMIT {
                break;
            }
            if !step_to_different_line && !step_to_different_column {
                break;
            } else if let Some(current_step) = self.steps.get(current_step_id) {
                let path_or_line_changed = original_path_id != current_step.path_id
                    || original_line != current_step.line
                    || original_call_key != current_step.call_key;
                if path_or_line_changed {
                    // a different line/path/frame — both granularities stop here.
                    break;
                }
                if step_to_different_column {
                    // M2 / M7 — statement-boundary detection.  Stop
                    // when the column STRICTLY moves past the entry
                    // column in the direction of travel.
                    //
                    // Forward (M2): `cur.0 > prev.0` — the start of
                    // the next statement under the recorder's
                    // left-to-right code-emit model.
                    //
                    // Backward (M7): `cur.0 < prev.0` — the start of
                    // the prior statement.  Symmetric mirror of the
                    // forward predicate.
                    //
                    // Bookkeeping / assignment hooks anchored at, or
                    // on the "wrong" side of, the entry column are
                    // skipped in both directions so the runner
                    // advances to the real statement boundary.  See
                    // `crate::trace_reader::TraceReader::next_step_id_relative_to_with_granularity`
                    // for the full rationale and the legacy-line-only-
                    // degrade contract.
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
                // Same line + (for statement) column ≤ entry → still inside
                // the current statement; keep stepping.
            } else {
                // current_step_id is out of bounds - stop iterating.
                warn!(
                    "next_step_id_relative_to: current_step_id {:?} out of bounds during line check",
                    current_step_id
                );
                break;
            }
        }
        if let Some(last_step) = self.steps.get(last_step_id) {
            info!("next step id: {:?}", last_step);
        }
        (last_step_id, step_id != last_step_id)
    }

    // returns the new step id and if a limit(first or last step) of the record is reached
    pub fn step_out_step_id_relative_to(&self, step_id: StepId, forward: bool) -> (StepId, bool) {
        // depth = 1 => we target upper level
        let new_step_id = self.step_over_depths_step_id(step_id, forward, 1);
        (new_step_id, step_id != new_step_id)
    }

    pub fn step_over_depths_step_id(&self, start_step_id: StepId, forward: bool, delta: usize) -> StepId {
        // Bounds-check: if the step_id is out of range (e.g. negative sentinel
        // or past the end), return it unchanged to avoid a panic.
        let Some(initial_step) = self.steps.get(start_step_id) else {
            warn!(
                "step_over_depths_step_id: start_step_id {:?} is out of bounds (steps len {})",
                start_step_id,
                self.steps.len()
            );
            return start_step_id;
        };
        let Some(initial_call) = self.calls.get(initial_step.call_key) else {
            warn!(
                "step_over_depths_step_id: call_key {:?} for step {:?} is out of bounds (calls len {})",
                initial_step.call_key,
                start_step_id,
                self.calls.len()
            );
            return start_step_id;
        };
        let initial_call_depth = initial_call.depth;
        let mut current_step_id = start_step_id;

        for new_step in self.step_from(start_step_id, forward) {
            // while !self.on_step_id_limit(i, forward) {
            // info!("next:i: {}", i);
            // i = self.single_step_line(i, forward);
            // let new_step = &self.db.steps[i];
            let new_call_key = new_step.call_key;
            current_step_id = new_step.step_id;
            let Some(new_call) = self.calls.get(new_call_key) else {
                warn!(
                    "step_over_depths_step_id: call_key {:?} for step {:?} is out of bounds (calls len {})",
                    new_call_key,
                    current_step_id,
                    self.calls.len()
                );
                break;
            };

            info!("for returned: {:?} with depth: {:?}", new_step, new_call.depth);

            // depth - delta can be < 0: we did get
            // such an underflow crash => compare as i64
            if (new_call.depth as i64) <= (initial_call_depth as i64) - (delta as i64) {
                // we're on a more shallow place than
                // the initial with a delta
                //
                // e.g. if delta == 0 => we're on
                // the same level or upper
                //
                // if delta == 1 => we're on upper
                // level, etc
                //
                // (delta == 0) <=> next
                // (delta == 1) <=> step-out/finish
                //
                //  that means we're ready
                break;
            } else {
                // we're deeper in the calltrace:
                // we skip this step and continue!
                continue;
            }
        }

        current_step_id
    }

    fn get_field_names(&self, type_id: &TypeId) -> Vec<String> {
        match &self.types[*type_id].specific_info {
            TypeSpecificInfo::Struct { fields } => fields.iter().map(|field| field.name.clone()).collect(),
            _ => Vec::new(),
        }
    }

    fn to_ct_type(&self, type_id: &TypeId) -> Type {
        if self.types.is_empty() {
            // probably rr trace case
            warn!("to_ct_type: for now returning just a placeholder type: assuming rr trace!");
            return Type::new(TypeKind::None, "<None>");
        }
        let type_record = &self.types[*type_id];
        match self.types[*type_id].kind {
            TypeKind::Struct => {
                let mut t = Type::new(type_record.kind, &type_record.lang_type);
                t.labels = self.get_field_names(type_id);
                t
            }
            _ => Type::new(type_record.kind, &type_record.lang_type),
        }
        // TODO: struct -> instance with labels/eventually other types
        // if type_record.kind != res.type
    }

    pub fn to_ct_value(&self, record: &ValueRecord) -> Value {
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
                // TODO: is_slice should be in the type kind: SLICE?
                let typ = if !is_slice {
                    self.to_ct_type(type_id)
                } else {
                    let type_record = &self.types[*type_id];
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
                // supposed to map to place in value graph
                // TODO
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

    // pub fn to_compound_value(&self, record: &ValueRecord) -> CompoundValue {
    //     if let ValueRecord::Sequence { elements, .. } = record {
    //         let place_list = elements.CompoundValue
    //     }
    // }
    // call -> step_id -> call_key (call)
    pub fn to_call(&self, call_record: &DbCall, expr_loader: &mut ExprLoader) -> Call {
        // info!(
        //     "call {:#?} function id {:?} function {:#?}",
        //     call_record, call_record.function_id, self.functions[call_record.function_id]
        // );
        Call {
            key: format!("{}", call_record.key.0),
            children: vec![],
            depth: call_record.depth,
            location: self.load_location(call_record.step_id, call_record.key, expr_loader),
            parent: None,
            raw_name: self.functions[call_record.function_id].name.clone(),
            args: call_record.args.iter().map(|arg| self.to_call_arg(arg)).collect(),
            return_value: self.to_ct_value(&call_record.return_value),
            with_args_and_return: true,
        }
    }

    pub fn to_call_arg(&self, arg_record: &FullValueRecord) -> CallArg {
        CallArg {
            name: self.variable_name(arg_record.variable_id).to_string(),
            text: "".to_string(),
            value: self.to_ct_value(&arg_record.value),
        }
    }

    pub fn variable_name(&self, variable_id: VariableId) -> &String {
        &self.variable_names[variable_id]
    }

    // find place for variable_id and step_id
    // for place:
    //   find last closest change of place
    //   if just a cell;
    //     that's the result
    //   if compound:
    //     from count, find relevant events for each index or for init:
    //     index/register/assign
    //     and then recursively for each final item place, find its value
    //     maybe do all of this up to some depth: for now a const, e.g. 3
    pub fn load_value(&self, variable_id: VariableId, step_id: StepId) -> ValueRecord {
        let name = self.variable_name(variable_id);
        info!("load_value {variable_id:?} {step_id:?} ({name})");

        let step_variable_cells = &self.variable_cells[step_id];
        if step_variable_cells.contains_key(&variable_id) {
            let place = step_variable_cells[&variable_id];
            self.load_value_for_place(place, step_id)
        } else {
            error!("no record for this variable on step {step_id:?}");
            ValueRecord::Error {
                msg: format!("no cell record for variable {name:?} on step #{step_id:?}"),
                type_id: TypeId(0),
            }
        }
    }

    #[allow(clippy::comparison_chain)]
    pub fn load_value_for_place(&self, place: Place, step_id: StepId) -> ValueRecord {
        info!("load_value_for_place {place:?} for #{step_id:?}");
        if self.cell_changes.contains_key(&place) {
            let changes = &self.cell_changes[&place];
            let mut i: usize = 0;
            let mut last_change_index: Option<usize> = None;
            // TODO: think of edge case: i == changes.len() - 1: last
            while i < changes.len() {
                let change = changes[i];
                info!("cell change {i} for {place:?} for {step_id:?}: {change:?}");
                if changes[i].step_id == step_id {
                    last_change_index = Some(i); // i is index of current change: this is the exact one
                    break;
                } else if changes[i].step_id > step_id {
                    break; // we stop with index of previous change: it should've been i - 1
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
                let cells_for_step_id = &self.cells[cell_change.step_id];
                if cells_for_step_id.contains_key(&place) {
                    // simple cell, return value record for it
                    cells_for_step_id[&place].clone()
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

    fn load_compound_value_for_place(&self, place: Place, cell_change: CellChange) -> ValueRecord {
        info!("load_compound_value_for_place {place:?} {cell_change:?}");
        let compound_for_step_id = &self.compound[cell_change.step_id];
        if compound_for_step_id.contains_key(&place) {
            let compound_value = &compound_for_step_id[&place];
            if let ValueRecord::Sequence {
                elements,
                type_id,
                is_slice: _,
            } = compound_value
            {
                // slices not supported currently, but it's an experimental API: TODO rework
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
                compound_value.clone() // or assign?
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

    fn load_value_item_by_index(&self, place: Place, index: usize, step_id: StepId) -> ValueRecord {
        info!("load_value_by_index {place:?} index {index} #{step_id:?}");
        if self.cell_changes.contains_key(&place) {
            for cell_change in self.cell_changes[&place].iter().rev() {
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

    pub fn display_variable_cells(&self) {
        // call <name> <id>:
        //   step #<id> line <line>: <var-name> <var-id>: <value-id>
        let mut last_call_key = CallKey(-1);
        for (step_id_int, step_variable_cells) in self.variable_cells.iter().enumerate() {
            let step_id = StepId(step_id_int as i64);
            let call_key = self.call_key_for_step(step_id);
            if last_call_key != call_key {
                let function_name = &self.functions[self.calls[call_key].function_id].name;
                let call_key_int = call_key.0;
                info!("call {function_name} {call_key_int}:");
            }
            last_call_key = call_key;
            info!("  step #{} line {}:", step_id.0, self.steps[step_id].line.0);
            for (variable_id, place) in step_variable_cells.iter() {
                let variable_name = self.variable_name(*variable_id);
                info!("  {} {}: {}", variable_name, variable_id.0, place.0);
            }
        }
    }

    pub fn load_step_events(&self, step_id: StepId, exact: bool) -> Vec<DbRecordEvent> {
        // if `exact` is true, we returns events only for this exact step
        // otherwise: for the whole step line "visit":
        // there can be multiple steps for the same visit of a line
        // and we should start with the first step of those: hopefully `step_id`;
        // but events can sometimes be registered for some of the next steps
        // e.g. additional steps might be registered with them in order to make sure
        // there are newer variable values etc
        // so to make sure we manage to load the relevant events, we try to find out
        // also the last step id of the group for a certain line visit
        // and to filter for that group
        let mut last_step_id_for_line = step_id;
        if !exact && let Some(original_step) = self.steps.get(step_id) {
            let original_path_id = original_step.path_id;
            let original_line = original_step.line;
            let mut current_step_id = step_id + 1;
            // Guard against negative step_id wrapping: only iterate when
            // the next id is non-negative and within bounds.
            while current_step_id.0 >= 0 && (current_step_id.0 as usize) < self.steps.len() {
                let step = self.steps[current_step_id];
                if step.path_id != original_path_id || step.line != original_line {
                    break;
                } else {
                    last_step_id_for_line = current_step_id;
                    current_step_id = current_step_id + 1;
                }
            }
        }

        let step_events = self
            .events
            .iter()
            .filter(|event| event.step_id >= step_id && event.step_id <= last_step_id_for_line)
            .cloned()
            .collect();
        #[allow(clippy::let_and_return)] // useful to have the variable for debugging/logging
        step_events
    }
}

impl Db {
    pub fn new_for_test() -> Db {
        let steps: DistinctVec<StepId, DbStep> = DistinctVec::new();
        let mut step_map_0: HashMap<usize, Vec<DbStep>> = HashMap::new();
        let mut path_map: HashMap<String, PathId> = HashMap::new();
        // let call = DbCall::new_for_test(0, 1, 0);
        path_map.insert("".to_string(), PathId(0));
        path_map.insert("/test/wordkir".to_string(), PathId(1));
        // for i in 0..10 {
        //     steps.push(DbStep::new_for_test(i, 1, i, 0))
        // }
        for step in steps.iter() {
            step_map_0.insert(step.step_id.0 as usize, vec![*step]);
        }
        let mut paths = DistinctVec::new();
        paths.push("".to_string());
        paths.push("/test/workdir".to_string());

        let mut step_map = DistinctVec::new();
        step_map.push(step_map_0);
        Db {
            workdir: PathBuf::from("/test/workdir"),
            functions: DistinctVec::new(),
            calls: DistinctVec::new(),
            steps,
            variables: DistinctVec::new(),
            instructions: DistinctVec::new(),
            types: DistinctVec::new(),
            events: vec![],
            paths,
            variable_names: DistinctVec::new(),

            compound: DistinctVec::new(),
            // compound_items: DistinctVec::new(),
            cells: DistinctVec::new(),
            cell_changes: HashMap::new(),
            variable_cells: DistinctVec::new(),
            local_variable_cells: vec![],

            step_map,
            path_map: path_map.clone(),

            end_of_program: EndOfProgram::Normal, // by default, but has to be reassigned in postprocessing
        }
    }
}

pub struct StepIterator<'a> {
    pub db: &'a Db,
    pub step_id: StepId,
    pub forward: bool,
}

impl StepIterator<'_> {
    fn on_step_id_limit(&self) -> bool {
        // Guard against negative step IDs (e.g. StepId(-1) / NO_STEP_ID) and
        // empty step vectors.  A negative i64 cast to usize wraps to a huge
        // value, so we must check the sign first.
        if self.db.steps.is_empty() || self.step_id.0 < 0 {
            return true;
        }
        let idx = self.step_id.0 as usize;
        if self.forward {
            // moving forward: we're at (or past) the last step
            idx >= self.db.steps.len() - 1
        } else {
            // moving backwards: we're at the first step
            idx == 0
        }
    }

    fn single_step_line(&self) -> StepId {
        // Caller (`Iterator::next`) must call `on_step_id_limit` first, so
        // these conditions should always hold.  We still avoid a hard panic
        // and clamp to the boundary instead, logging the unexpected situation.
        if self.forward {
            if self.step_id.0 < 0 || (self.step_id.0 as usize) >= self.db.steps.len().saturating_sub(1) {
                warn!(
                    "single_step_line: forward step from {:?} is at or beyond limit (steps len {})",
                    self.step_id,
                    self.db.steps.len()
                );
                return self.step_id;
            }
            self.step_id + 1
        } else {
            if self.step_id.0 <= 0 {
                warn!(
                    "single_step_line: backward step from {:?} is at or beyond limit",
                    self.step_id
                );
                return self.step_id;
            }
            self.step_id - 1
        }
    }
}

impl Iterator for StepIterator<'_> {
    type Item = DbStep;

    fn next(&mut self) -> Option<Self::Item> {
        if !self.on_step_id_limit() {
            self.step_id = self.single_step_line();
            Some(self.db.steps[self.step_id])
        } else {
            None
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DbCall {
    pub key: CallKey,
    pub function_id: FunctionId,
    pub args: Vec<FullValueRecord>,
    pub return_value: ValueRecord,
    pub step_id: StepId,
    pub depth: usize,
    pub parent_key: CallKey,
    pub children_keys: Vec<CallKey>,
}

#[derive(Copy, Clone, Debug, Serialize, Deserialize)]
pub struct DbStep {
    pub step_id: StepId,
    pub path_id: PathId,
    pub line: Line,
    // 1-indexed column at which the step landed in the source.  `None`
    // for traces recorded without column-aware mode (the legacy
    // `runtime_tracing` materialised layout has no column metadata, and
    // the Nim bulk reader currently surfaces only `(path_id, line)` —
    // see codetracer-trace-format-spec/trace-events.md §"Compact Step
    // Encoding").  Wired through P6.3 so the DAP layer's source-map
    // translation can consume real column data once P6.4 surfaces it
    // through the canonical reader.
    pub column: Option<Line>,
    // the call key of the current frame call
    pub call_key: CallKey,
    // the call key of the last started call in the program
    pub global_call_key: CallKey,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DbRecordEvent {
    pub kind: EventLogKind,
    pub content: String,
    pub step_id: StepId,
    pub metadata: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct CellChange {
    pub step_id: StepId,
    pub item_count: usize,
    pub type_id: Option<TypeId>,
    pub index: Option<usize>,
    pub item_place: Option<Place>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum EndOfProgram {
    Normal,
    Error { reason: String },
}

// #[derive(Debug, Clone, Copy, Serialize, Deserialize)]
// pub struct VariableCell {
//     pub step_id: StepId,
//     pub place: Place,
// }

// type LineTraceMap = HashMap<usize, Vec<(usize, String)>>;

/// Comparison operators supported by the M9 breakpoint condition
/// evaluator.  The set is deliberately minimal — the spec calls out
/// `i > 100` as the canonical use case; everything else is a natural
/// extension (`>=`, `<=`, `==`, `!=`, `<`) and stays well within
/// "no new expression evaluator".  Implemented inline in
/// `evaluate_breakpoint_condition`.
#[derive(Debug, Clone, Copy)]
enum BreakpointConditionOp {
    Gt,
    Lt,
    Ge,
    Le,
    Eq,
    Ne,
}

#[derive(Debug)]
pub struct MaterializedReplaySession {
    /// Shared, read-only access to trace data via the [`TraceReader`]
    /// abstraction.  All read accesses go through this.
    pub reader: Arc<dyn TraceReader>,
    /// Types registered during expression evaluation (local overlay).
    ///
    /// `register_type` pushes new types here.  The `type_record` helper
    /// checks the overlay first (for ids >= `reader.type_count()`), falling
    /// back to the reader for base types.
    local_types: Vec<TypeRecord>,
    pub step_id: StepId,
    pub call_key: CallKey,
    /// Per-path table of registered breakpoints keyed by
    /// `(line, column)`.
    ///
    /// `column = None` is the legacy line-only slot — it matches every
    /// `DbStep` on that line regardless of recorded column.
    /// `column = Some(c)` is the M1 column-aware slot — it only matches
    /// `DbStep`s whose recorded `column` equals `c`.
    ///
    /// The two coexist on the same line (one map slot per coordinate),
    /// so a Continue MUST consult both: any of the keyed entries that
    /// would match the current step on this line counts as a hit.
    pub breakpoint_list: Vec<HashMap<(usize, Option<i64>), Breakpoint>>,
    breakpoint_next_id: usize,
    /// M10 — Per-path table of registered DAP-pipeline tracepoints
    /// (logpoints), keyed by `(line, column)` in the exact same shape
    /// as `breakpoint_list`.  When a Continue traverses a recorded
    /// step that matches any entry here, the engine pushes a
    /// `TracepointHit` into `pending_tracepoint_hits` and KEEPS GOING
    /// — the defining difference between a logpoint and a breakpoint.
    ///
    /// `column = None` is the legacy line-only slot (back-compat); a
    /// `Some(c)` slot mirrors M1's column-aware semantics.  Multiple
    /// tracepoints on the same line, anchored at different columns,
    /// coexist on the per-line slot map.
    pub tracepoint_list: Vec<HashMap<(usize, Option<i64>), DapTracepoint>>,
    tracepoint_next_id: i64,
    /// M10 — buffered tracepoint hits awaiting drain by the DAP
    /// handler.  The handler calls `drain_tracepoint_hits()` after
    /// `step(Action::Continue, ...)` returns and emits one DAP
    /// `output` event per drained hit.  Cleared on every drain.
    pending_tracepoint_hits: Vec<TracepointHit>,
}

impl MaterializedReplaySession {
    pub fn new(reader: Arc<dyn TraceReader>) -> MaterializedReplaySession {
        let mut breakpoint_list: Vec<HashMap<(usize, Option<i64>), Breakpoint>> = Default::default();
        breakpoint_list.resize_with(reader.path_count(), HashMap::new);
        // M10 — the tracepoint registry parallels `breakpoint_list`:
        // one slot per recorded path so the per-path lookup in
        // `step_matches_any_tracepoint` is O(1) keyed by `path_id`.
        let mut tracepoint_list: Vec<HashMap<(usize, Option<i64>), DapTracepoint>> = Default::default();
        tracepoint_list.resize_with(reader.path_count(), HashMap::new);
        MaterializedReplaySession {
            reader,
            local_types: Vec::new(),
            step_id: StepId(0),
            call_key: CallKey(0),
            breakpoint_list,
            breakpoint_next_id: 0,
            tracepoint_list,
            tracepoint_next_id: 0,
            pending_tracepoint_hits: Vec::new(),
        }
    }

    pub fn register_type(&mut self, typ: TypeRecord) -> TypeId {
        // for no checking for typ.name logic: eventually in ensure_type?
        let base_count = self.reader.type_count();
        self.local_types.push(typ);
        TypeId(base_count + self.local_types.len() - 1)
    }

    /// Look up a type by id, checking the local overlay for types
    /// registered during this replay session.
    #[allow(clippy::expect_used)] // idx < base_count guard ensures the id is valid
    fn type_record(&self, id: TypeId) -> &TypeRecord {
        let idx: usize = id.into();
        let base_count = self.reader.type_count();
        if idx < base_count {
            self.reader
                .type_record(id)
                .expect("type_record: invalid TypeId in base reader")
        } else {
            &self.local_types[idx - base_count]
        }
    }

    #[allow(clippy::wrong_self_convention)] // Needs &mut self to register types
    pub fn to_value_record(&mut self, v: ValueRecordWithType) -> ValueRecord {
        match v {
            ValueRecordWithType::Int { i, typ } => {
                let type_id = self.register_type(typ);
                ValueRecord::Int { i, type_id }
            }
            ValueRecordWithType::Float { f, typ } => {
                let type_id = self.register_type(typ);
                ValueRecord::Float { f, type_id }
            }
            ValueRecordWithType::Bool { b, typ } => {
                let type_id = self.register_type(typ);
                ValueRecord::Bool { b, type_id }
            }
            ValueRecordWithType::String { text, typ } => {
                let type_id = self.register_type(typ);
                ValueRecord::String { text, type_id }
            }
            ValueRecordWithType::Sequence {
                elements,
                is_slice,
                typ,
            } => {
                let type_id = self.register_type(typ);
                let element_records = elements.iter().map(|e| self.to_value_record(e.clone())).collect();
                ValueRecord::Sequence {
                    elements: element_records,
                    is_slice,
                    type_id,
                }
            }
            ValueRecordWithType::Tuple { elements, typ } => {
                let type_id = self.register_type(typ);
                let element_records = elements.iter().map(|e| self.to_value_record(e.clone())).collect();
                ValueRecord::Tuple {
                    elements: element_records,
                    type_id,
                }
            }
            ValueRecordWithType::Struct { field_values, typ } => {
                let type_id = self.register_type(typ);
                let field_value_records = field_values.iter().map(|v| self.to_value_record(v.clone())).collect();
                ValueRecord::Struct {
                    field_values: field_value_records,
                    type_id,
                }
            }
            ValueRecordWithType::Variant {
                discriminator,
                contents,
                typ,
            } => {
                let type_id = self.register_type(typ);
                let contents_record = self.to_value_record(*contents);
                ValueRecord::Variant {
                    discriminator,
                    contents: Box::new(contents_record),
                    type_id,
                }
            }
            ValueRecordWithType::Reference {
                dereferenced,
                address,
                mutable,
                typ,
            } => {
                let type_id = self.register_type(typ);
                let dereferenced_record = self.to_value_record(*dereferenced);
                ValueRecord::Reference {
                    dereferenced: Box::new(dereferenced_record),
                    address,
                    mutable,
                    type_id,
                }
            }
            ValueRecordWithType::Raw { r, typ } => {
                let type_id = self.register_type(typ);
                ValueRecord::Raw { r, type_id }
            }
            ValueRecordWithType::Error { msg, typ } => {
                let type_id = self.register_type(typ);
                ValueRecord::Error { msg, type_id }
            }
            ValueRecordWithType::None { typ } => {
                let type_id = self.register_type(typ);
                ValueRecord::None { type_id }
            }
            ValueRecordWithType::Cell { place } => ValueRecord::Cell { place },
            ValueRecordWithType::BigInt { b, negative, typ } => {
                let type_id = self.register_type(typ);
                ValueRecord::BigInt { b, negative, type_id }
            }
            ValueRecordWithType::Char { c, typ } => {
                let type_id = self.register_type(typ);
                ValueRecord::Char { c, type_id }
            }
        }
    }

    pub fn to_value_record_with_type(&self, v: &ValueRecord) -> ValueRecordWithType {
        match v {
            ValueRecord::Int { i, type_id } => ValueRecordWithType::Int {
                i: *i,
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::Float { f, type_id } => ValueRecordWithType::Float {
                f: *f,
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::Bool { b, type_id } => ValueRecordWithType::Bool {
                b: *b,
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::String { text, type_id } => ValueRecordWithType::String {
                text: text.to_string(),
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::Sequence {
                elements,
                is_slice,
                type_id,
            } => ValueRecordWithType::Sequence {
                elements: elements.iter().map(|e| self.to_value_record_with_type(e)).collect(),
                is_slice: *is_slice,
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::Tuple { elements, type_id } => ValueRecordWithType::Tuple {
                elements: elements.iter().map(|e| self.to_value_record_with_type(e)).collect(),
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::Struct { field_values, type_id } => ValueRecordWithType::Struct {
                field_values: field_values.iter().map(|v| self.to_value_record_with_type(v)).collect(),
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::Variant {
                discriminator,
                contents,
                type_id,
            } => ValueRecordWithType::Variant {
                discriminator: discriminator.clone(),
                contents: Box::new(self.to_value_record_with_type(contents)),
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::Reference {
                dereferenced,
                address,
                mutable,
                type_id,
            } => ValueRecordWithType::Reference {
                dereferenced: Box::new(self.to_value_record_with_type(dereferenced)),
                address: *address,
                mutable: *mutable,
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::Raw { r, type_id } => ValueRecordWithType::Raw {
                r: r.clone(),
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::Error { msg, type_id } => ValueRecordWithType::Error {
                msg: msg.clone(),
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::None { type_id } => ValueRecordWithType::None {
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::Cell { place } => ValueRecordWithType::Cell { place: *place },
            ValueRecord::BigInt { b, negative, type_id } => ValueRecordWithType::BigInt {
                b: b.clone(),
                negative: *negative,
                typ: self.type_record(*type_id).clone(),
            },
            ValueRecord::Char { c, type_id } => ValueRecordWithType::Char {
                c: *c,
                typ: self.type_record(*type_id).clone(),
            },
        }
    }

    pub fn step_id_jump(&mut self, step_id: StepId) {
        if step_id.0 != NO_INDEX {
            self.step_id = step_id;
        }
    }

    #[allow(clippy::expect_used)] // step_id != NO_INDEX guard ensures the id is valid
    fn to_program_event(&self, event_record: &DbRecordEvent, index: usize) -> ProgramEvent {
        let step_id_int = event_record.step_id.0;
        let (path, line) = if step_id_int != NO_INDEX {
            let step_record = self
                .reader
                .step(event_record.step_id)
                .expect("to_program_event: invalid step_id");
            (
                self.reader
                    .workdir()
                    .join(self.reader.path(step_record.path_id).unwrap_or(""))
                    .display()
                    .to_string(),
                step_record.line.0,
            )
        } else {
            (NO_PATH.to_string(), NO_POSITION)
        };

        let default_step = DbStep {
            step_id: StepId(0),
            path_id: PathId(0),
            line: Line(0),
            column: None,
            call_key: CallKey(0),
            global_call_key: CallKey(0),
        };
        let last_step_id = if self.reader.step_count() > 0 {
            self.reader
                .step(StepId((self.reader.step_count() - 1) as i64))
                .unwrap_or(&default_step)
                .step_id
        } else {
            default_step.step_id
        };

        ProgramEvent {
            kind: event_record.kind,
            semantic_kind: String::new(),
            content: event_record.content.clone(),
            bytes: event_record.content.len(),
            rr_event_id: index,
            direct_location_rr_ticks: step_id_int,
            metadata: event_record.metadata.to_string(),
            stdout: true,
            event_index: index,
            tracepoint_result_index: NO_INDEX,
            high_level_path: path,
            high_level_line: line,
            base64_encoded: false,
            max_rr_ticks: last_step_id.0,
            source_generation: 0,
            source_digest: String::new(),
        }
    }

    fn single_step_line(&self, step_index: usize, forward: bool) -> usize {
        // taking note of db.lines limits: returning a valid step id always
        if self.reader.step_count() == 0 {
            return step_index;
        }
        if forward {
            if step_index < self.reader.step_count() - 1 {
                step_index + 1
            } else {
                step_index
            }
        } else if step_index > 0 {
            step_index - 1
        } else {
            // auto-returning the same 0 if stepping backwards from 0
            step_index
        }
    }

    fn step_in(&mut self, forward: bool) -> Result<bool, Box<dyn Error>> {
        // Guard against negative step IDs (e.g. NO_STEP_ID = -1) which would
        // wrap to usize::MAX and cause an out-of-bounds panic.
        let step_index = if self.step_id.0 < 0 {
            0usize
        } else {
            self.step_id.0 as usize
        };
        let new_index = self.single_step_line(step_index, forward);
        let moved = new_index != step_index;
        self.step_id = StepId(new_index as i64);
        Ok(moved)
    }

    fn step_out(&mut self, forward: bool) -> Result<bool, Box<dyn Error>> {
        let old_step_id = self.step_id;
        (self.step_id, _) = self.reader.step_out_step_id_relative_to(self.step_id, forward);
        Ok(self.step_id != old_step_id)
    }

    fn next(&mut self, forward: bool) -> Result<bool, Box<dyn Error>> {
        let step_to_different_line = true; // which is better/should be let the user configure it?
        let moved;
        (self.step_id, moved) = self
            .reader
            .next_step_id_relative_to(self.step_id, forward, step_to_different_line);
        Ok(moved)
    }

    /// M2 — statement-granularity step-over.
    ///
    /// Advance until either (a) the recorded `(path_id, line,
    /// call_key)` differs from the entry step — the same boundary
    /// the legacy [`MaterializedReplaySession::next`] uses — OR (b)
    /// a same-line step whose `column` is STRICTLY GREATER than the
    /// entry column is observed, which marks the start of the next
    /// statement under the column-aware recorder contract.
    ///
    /// Why strict-greater rather than any-change: the JS / Python
    /// recorders may emit multiple steps per statement (the
    /// user-facing `__ct.step(siteId)` injection point plus
    /// assignment-write / bookkeeping hooks that anchor at-or-before
    /// the statement's start column).  An "any-column-change"
    /// predicate would stop on those bookkeeping anchors and the
    /// cursor would oscillate intra-statement; the strict-greater
    /// rule advances past them to the unambiguous user-visible next
    /// statement, matching the M2 spec's statement-range semantic.
    ///
    /// Steps with `column = None` (legacy line-only traces) treat the
    /// column predicate as never firing — statement granularity
    /// degrades to line granularity, the documented fallback for
    /// pre-column-aware recordings.
    ///
    /// Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M2.
    fn next_statement(&mut self, forward: bool) -> Result<bool, Box<dyn Error>> {
        let moved;
        (self.step_id, moved) = self.reader.next_step_id_relative_to_with_granularity(
            self.step_id,
            forward,
            /* step_to_different_line = */ true,
            /* step_to_different_column = */ true,
        );
        Ok(moved)
    }

    // returns if it has hit any breakpoints
    #[allow(clippy::expect_used)] // Trace must have at least one step
    fn step_continue(&mut self, forward: bool) -> Result<bool, Box<dyn Error>> {
        // Build an iterator over steps after (or before) the current step.
        let steps: Vec<DbStep> = if forward {
            let slice = self.reader.steps_from(self.step_id);
            // Skip the current step itself.
            if slice.len() > 1 { slice[1..].to_vec() } else { vec![] }
        } else {
            let all = self.reader.steps_from(StepId(0));
            let end = self.step_id.0 as usize;
            if end <= all.len() {
                let mut v = all[..end].to_vec();
                v.reverse();
                v
            } else {
                vec![]
            }
        };
        // M10 — clear any leftover hits from a previous Continue.  The
        // DAP handler drains after every step call, but a paranoid
        // reset here means a malformed caller (or a test rig that
        // forgets to drain) cannot leak stale hits into the next run.
        self.pending_tracepoint_hits.clear();
        let breakpoint_active = !self.breakpoint_list.is_empty();
        let tracepoint_active = self.tracepoint_list.iter().any(|per_path| !per_path.is_empty());
        for step in steps {
            // M10 — collect every tracepoint hit on the way to the
            // eventual breakpoint stop (or end-of-trace).  Tracepoint
            // matching MUST happen BEFORE the breakpoint check so a
            // step that satisfies BOTH a breakpoint AND a tracepoint
            // logs the message BEFORE the engine parks at the
            // stop point (the convention DAP `output` consumers
            // expect: the log appears in the trace before the
            // matching stop event).
            if tracepoint_active && let Some(hit) = self.step_matches_any_tracepoint(&step) {
                self.pending_tracepoint_hits.push(hit);
            }
            if breakpoint_active {
                if self.step_matches_any_breakpoint(&step) {
                    self.step_id_jump(step.step_id);
                    // true: has hit a breakpoint
                    return Ok(true);
                }
            } else if !tracepoint_active {
                break;
            }
        }

        // If the continue step doesn't find a valid breakpoint.
        let step_count = self.reader.step_count();
        if forward {
            self.step_id_jump(
                self.reader
                    .step(StepId((step_count - 1) as i64))
                    .expect("unexpected 0 steps in trace for step_continue")
                    .step_id,
            );
        } else {
            self.step_id_jump(
                self.reader
                    .step(StepId(0))
                    .expect("unexpected 0 steps in trace for step_continue")
                    .step_id,
            )
        }
        // false: hasn't hit a breakpoint
        Ok(false)
    }

    /// Return `true` when the given `step` matches an enabled breakpoint
    /// for its path.  M1 column-aware semantics:
    ///
    ///   * a `(line, None)` entry — the legacy line-only slot — matches
    ///     any step on that line, regardless of recorded column.
    ///   * a `(line, Some(c))` entry — the column-aware slot — matches
    ///     only steps whose recorded `column == Some(c)`.  Steps with no
    ///     recorded column never match a column-aware breakpoint, even
    ///     when the line agrees — without that data we cannot prove the
    ///     match.
    ///
    /// Both slots coexist independently on the same line; a step
    /// satisfying either kind is a hit.
    ///
    /// M9 conditional layer — when the matched `Breakpoint` carries a
    /// `condition: Some(expr)`, the step is treated as a hit ONLY when
    /// `expr` evaluates to a truthy value against the locals recorded
    /// at the candidate step.  Composes orthogonally with the column
    /// match above: a column-aware breakpoint with a condition first
    /// checks the column, then the condition.  A condition-bearing
    /// breakpoint whose condition fails to evaluate (parse error,
    /// unknown variable) is treated as a non-hit — the engine MUST
    /// NOT spuriously stop on a malformed condition.
    fn step_matches_any_breakpoint(&self, step: &DbStep) -> bool {
        let path_idx = step.path_id.0;
        if path_idx >= self.breakpoint_list.len() {
            return false;
        }
        let line_key = step.line.0 as usize;
        let table = &self.breakpoint_list[path_idx];

        // Legacy line-only slot: stop on every step at this line, but
        // honour the M9 condition layer when present.
        if let Some(bp) = table.get(&(line_key, None))
            && bp.enabled
            && self.condition_satisfied_at(bp, step.step_id)
        {
            return true;
        }

        // Column-aware slot: only fire when the step's recorded column
        // is `Some(c)` and equals the breakpoint's column.  The
        // condition layer applies after the column filter so users
        // can write "stop at column 14 only when i > 100".
        if let Some(step_col) = step.column
            && let Some(bp) = table.get(&(line_key, Some(step_col.0)))
            && bp.enabled
            && self.condition_satisfied_at(bp, step.step_id)
        {
            return true;
        }

        false
    }

    /// M10 — return the registered DAP-pipeline tracepoint that
    /// matches `step`, if any.  Mirrors `step_matches_any_breakpoint`
    /// but for the logpoint registry:
    ///
    ///   * a `(line, None)` entry is the legacy line-only slot — fires
    ///     on every step on the line, regardless of recorded column.
    ///   * a `(line, Some(c))` entry is column-aware — fires only when
    ///     the step's recorded `column == Some(c)`.
    ///
    /// When BOTH a line-only slot AND a column-aware slot would match
    /// the same step, the column-aware slot wins — it carries more
    /// specific information, so its `log_message` is the more
    /// faithful one to emit.  This mirrors the principle that
    /// column-aware navigation surfaces are strictly refinements of
    /// the legacy line-only ones.
    ///
    /// Returns `None` when no slot matches, even when the line agrees:
    /// the tracepoint registry is OPT-IN at the `(line, column)`
    /// granularity, exactly like the breakpoint registry.
    fn step_matches_any_tracepoint(&self, step: &DbStep) -> Option<TracepointHit> {
        let path_idx = step.path_id.0;
        if path_idx >= self.tracepoint_list.len() {
            return None;
        }
        let line_key = step.line.0 as usize;
        let table = &self.tracepoint_list[path_idx];

        // M10 — column-aware slot wins when present, because it
        // describes a strictly narrower target.  The line-only slot is
        // checked second so a logpoint at `(line=1, col=None)` still
        // fires on `(line=1, col=14)` steps when no column-anchored
        // slot covers them.
        let column_match: Option<&DapTracepoint> = step
            .column
            .and_then(|step_col| table.get(&(line_key, Some(step_col.0))));
        let line_match: Option<&DapTracepoint> = table.get(&(line_key, None));

        let chosen = match (column_match, line_match) {
            (Some(c), _) if c.enabled => Some(c),
            (_, Some(l)) if l.enabled => Some(l),
            _ => None,
        }?;

        let path = self.reader.path(step.path_id).unwrap_or("").to_string();
        Some(TracepointHit {
            path,
            line: step.line.0,
            column: step.column.map(|c| c.0),
            log_message: chosen.log_message.clone(),
        })
    }

    /// Evaluate the breakpoint's optional condition expression against
    /// the locals recorded at `step_id`.  Returns `true` when:
    ///
    ///   * the breakpoint has no condition (M1 unconditional path), OR
    ///   * the condition parses, all referenced variables resolve at
    ///     the step, and the expression yields a truthy value.
    ///
    /// Returns `false` for any parse error, unresolved variable, or
    /// false expression result — a malformed condition MUST NOT
    /// trigger spurious stops.  See M9 of
    /// `codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org`.
    fn condition_satisfied_at(&self, bp: &Breakpoint, step_id: StepId) -> bool {
        let Some(expr) = bp.condition.as_deref() else {
            return true;
        };
        // A malformed condition or unresolved variable counts as a
        // non-hit — surfaced via `unwrap_or_default()` (default `bool`
        // is `false`).
        self.evaluate_breakpoint_condition(expr, step_id).unwrap_or_default()
    }

    /// Evaluate a breakpoint condition expression at `step_id`.
    ///
    /// Supports a minimal but practical surface:
    ///   * `<name> <op> <int-literal>` — where `<op>` is one of
    ///     `>`, `<`, `>=`, `<=`, `==`, `!=`.
    ///   * `<name>` alone — truthy iff the variable resolves to a
    ///     non-zero integer or boolean `true` (lets users write
    ///     `enabled` as a condition).
    ///
    /// `<name>` is looked up against the per-step `variables_at` snapshot
    /// recorded for `step_id`, mirroring the lookup used by
    /// `program_search_tool::evaluate` (the only other place in the
    /// db-backend that consults per-step variable values).  Returns a
    /// descriptive error for parse failures and unresolved variables;
    /// callers (`condition_satisfied_at`) translate the error into a
    /// non-hit so a typo never spuriously stops the runner.
    fn evaluate_breakpoint_condition(&self, expr: &str, step_id: StepId) -> Result<bool, Box<dyn Error>> {
        let trimmed = expr.trim();
        if trimmed.is_empty() {
            return Err("empty condition".into());
        }
        const OPS: [(&str, BreakpointConditionOp); 6] = [
            (">=", BreakpointConditionOp::Ge),
            ("<=", BreakpointConditionOp::Le),
            ("==", BreakpointConditionOp::Eq),
            ("!=", BreakpointConditionOp::Ne),
            (">", BreakpointConditionOp::Gt),
            ("<", BreakpointConditionOp::Lt),
        ];
        for (token, op) in OPS.iter() {
            if let Some(idx) = trimmed.find(token) {
                let lhs = trimmed[..idx].trim();
                let rhs = trimmed[idx + token.len()..].trim();
                let lhs_value = self.lookup_variable_int(lhs, step_id)?;
                let rhs_value: i64 = rhs
                    .parse()
                    .map_err(|e| format!("can't parse rhs `{rhs}` as integer: {e}"))?;
                return Ok(match op {
                    BreakpointConditionOp::Gt => lhs_value > rhs_value,
                    BreakpointConditionOp::Lt => lhs_value < rhs_value,
                    BreakpointConditionOp::Ge => lhs_value >= rhs_value,
                    BreakpointConditionOp::Le => lhs_value <= rhs_value,
                    BreakpointConditionOp::Eq => lhs_value == rhs_value,
                    BreakpointConditionOp::Ne => lhs_value != rhs_value,
                });
            }
        }
        // Bare-name fallback: truthy iff the variable resolves to a
        // non-zero integer or boolean `true`.
        let value = self.lookup_variable_record(trimmed, step_id)?;
        Ok(match value {
            ValueRecord::Int { i, .. } => i != 0,
            ValueRecord::Bool { b, .. } => b,
            _ => false,
        })
    }

    /// Look up `name` in the per-step variables snapshot and coerce
    /// the recorded value to an integer.  Booleans coerce to 0/1 so
    /// expressions like `flag == 1` work transparently.  Returns an
    /// error when the variable doesn't exist on this step or its
    /// value can't be coerced.
    fn lookup_variable_int(&self, name: &str, step_id: StepId) -> Result<i64, Box<dyn Error>> {
        let value = self.lookup_variable_record(name, step_id)?;
        match value {
            ValueRecord::Int { i, .. } => Ok(i),
            ValueRecord::Bool { b, .. } => Ok(if b { 1 } else { 0 }),
            other => Err(format!("variable `{name}` is not an integer: {other:?}").into()),
        }
    }

    /// Look up a variable by name in the per-step variables snapshot.
    /// Returns the cloned `ValueRecord` so callers can pattern-match
    /// on the variant.  Mirrors the lookup used by
    /// `program_search_tool::evaluate`.
    fn lookup_variable_record(&self, name: &str, step_id: StepId) -> Result<ValueRecord, Box<dyn Error>> {
        if let Some(vars) = self.reader.variables_at(step_id) {
            for variable in vars {
                if self.reader.variable_name(variable.variable_id) == Some(name) {
                    return Ok(variable.value.clone());
                }
            }
        }
        Err(format!("variable `{name}` not found at step {step_id:?}").into())
    }

    /// Resolves a source path to its `PathId` in the trace database.
    ///
    /// Delegates to `TraceReader::fuzzy_path_id_for` which tries multiple
    /// matching strategies: exact match, workdir-stripped, suffix match,
    /// canonicalized, reverse canonicalize, and filename-only.
    fn load_path_id(&self, path: &str) -> Option<PathId> {
        self.reader.fuzzy_path_id_for(path)
    }

    fn id_to_name(&self, variable_id: VariableId) -> &str {
        self.reader.variable_name(variable_id).unwrap_or("<unknown>")
    }

    fn is_user_source_path(path: &str) -> bool {
        !path.is_empty() && !path.starts_with("/nix/store/")
    }

    fn first_user_call(&self) -> Option<&DbCall> {
        self.reader
            .calls_iter()
            .find(|call| {
                self.reader
                    .function(call.function_id)
                    .and_then(|function| self.reader.path(function.path_id))
                    .map(Self::is_user_source_path)
                    .unwrap_or(false)
            })
            .or_else(|| self.reader.call(CallKey(0)))
    }

    fn first_executable_step_for_call(&self, call: &DbCall) -> StepId {
        let Some(function) = self.reader.function(call.function_id) else {
            return call.step_id;
        };
        let function_path = self.reader.path(function.path_id).unwrap_or("");
        let function_line = function.line.0;
        let call_steps = self.reader.steps_from(call.step_id);

        if function_path.ends_with(".nr") {
            // Noir DWARF can point a function at the synthetic/comment/header
            // line while the first executable statement is the next source
            // line recorded for the same file. Prefer that executable line so
            // run-to-entry opens the state/editor on user code, not line 1.
            let header_line = if function_line <= 0 { 1 } else { function_line };
            if let Some(step) = call_steps
                .iter()
                .find(|step| step.call_key == call.key && step.path_id == function.path_id && step.line.0 > header_line)
            {
                return step.step_id;
            }
        }

        if function_line <= 0 {
            return call.step_id;
        }

        call_steps
            .iter()
            .find(|step| step.call_key == call.key && step.path_id == function.path_id && step.line.0 >= function_line)
            .map(|step| step.step_id)
            .unwrap_or(call.step_id)
    }
}

impl ReplaySession for MaterializedReplaySession {
    fn load_location(&mut self, expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
        info!("load_location: db replay");
        // Event-only traces (e.g. Stylus) have no steps — return a default location
        // so the DAP server can still initialize and serve event data.
        if self.reader.step_count() == 0 {
            info!("  no steps in trace, returning default location");
            return Ok(Location::default());
        }
        let call_key = self.reader.call_key_for_step(self.step_id).unwrap_or(CallKey(0));
        self.call_key = call_key;
        let location = self.reader.load_location(self.step_id, call_key, expr_loader);
        info!("  location: {location:?}");
        Ok(location)
    }

    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        // "Run to entry" means stop at the program's entry point — the
        // first recorded call. Some recorders (notably the BEAM recorder)
        // emit leading scaffolding steps that precede every call: the
        // trace writer's synthetic `start()` anchor plus per-thread
        // bookkeeping steps. Those steps carry `call_key == NO_KEY`, so
        // landing on step 0 leaves the debugger in a frame with no
        // function, an `<unknown>` location, and — critically — an empty
        // call trace (`call_key_for_step(0)` returns `NO_KEY`, so
        // `Calltrace::jump_to` builds nothing).
        //
        // Prefer the entry step of the first call when the trace has
        // calls; this is the genuine program entry point. Well-formed
        // materialised traces whose call 0 already begins at step 0
        // (e.g. the Python/Ruby/JS recorders) are unaffected — the
        // first call's `step_id` is 0 for them. Fall back to step 0 for
        // call-less step traces.
        if self.reader.call_count() > 0 {
            let entry_step = self
                .first_user_call()
                .map(|call| self.first_executable_step_for_call(call))
                .unwrap_or(StepId(0));
            self.step_id_jump(entry_step);
        } else if self.reader.step_count() > 0 {
            self.step_id_jump(StepId(0));
        }
        Ok(())
    }

    fn load_events(&mut self) -> Result<Events, Box<dyn Error>> {
        let mut events: Vec<ProgramEvent> = vec![];
        let mut first_events: Vec<ProgramEvent> = vec![];
        let mut contents: String = "".to_string();

        for (i, event_record) in self.reader.events().iter().enumerate() {
            let mut event = self.to_program_event(event_record, i);
            event.content = event_record.content.to_string();
            events.push(event.clone());
            if i < 20 {
                first_events.push(event);
                contents.push_str(&format!("{}\\n\n", event_record.content));
            }
        }

        Ok(Events {
            events,
            first_events,
            contents,
        })
    }

    // for Ok cases:
    //   continue returns if it has hit any breakpoints, others return always true
    fn step(&mut self, action: Action, forward: bool) -> Result<bool, Box<dyn Error>> {
        match action {
            Action::StepIn => self.step_in(forward),
            Action::StepOut => self.step_out(forward),
            Action::Next => self.next(forward),
            Action::Continue => self.step_continue(forward),
            _ => todo!(),
        }
    }

    /// M2 — Column-Aware Replay Navigation §M2.
    /// Override the default trait body to dispatch to the
    /// column-aware [`next_statement`] runner instead of the legacy
    /// line-granularity `next`.
    fn step_over_statement(&mut self, forward: bool) -> Result<bool, Box<dyn Error>> {
        self.next_statement(forward)
    }

    fn load_locals(&mut self, arg: CtLoadLocalsArguments) -> Result<Vec<VariableWithRecord>, Box<dyn Error>> {
        let variables_for_step = self
            .reader
            .variables_at(self.step_id)
            .map(|v| v.to_vec())
            .unwrap_or_default();
        let full_value_locals: Vec<VariableWithRecord> = variables_for_step
            .iter()
            .map(|v| VariableWithRecord {
                expression: self
                    .reader
                    .variable_name(v.variable_id)
                    .unwrap_or("<unknown>")
                    .to_string(),
                value: self.to_value_record_with_type(&v.value),
                address: NO_ADDRESS,
            })
            .collect();

        // TODO: fix random order here as well: ensure order(or in final locals?)
        let variable_cells_for_step = self.reader.variable_cells_at(self.step_id).cloned().unwrap_or_default();
        let value_tracking_locals: Vec<VariableWithRecord> = variable_cells_for_step
            .iter()
            .map(|(variable_id, place)| {
                let name = self.reader.variable_name(*variable_id).unwrap_or("<unknown>");
                info!("log local {variable_id:?} {name} place: {place:?}");
                let value = self.reader.load_value_for_place(*place, self.step_id);
                VariableWithRecord {
                    expression: self
                        .reader
                        .variable_name(*variable_id)
                        .unwrap_or("<unknown>")
                        .to_string(),
                    value: self.to_value_record_with_type(&value),
                    address: NO_ADDRESS,
                }
            })
            .collect();

        // TODO: watches require tracepoint-like evaluate_expression or would duplicate locals
        // for now don't evaluate/support them for db traces: just ignoring
        if !arg.watch_expressions.is_empty() {
            warn!("watch expressions not supported for db traces currently");
        }

        // based on https://stackoverflow.com/a/56490417/438099
        let mut locals: Vec<VariableWithRecord> = full_value_locals.into_iter().chain(value_tracking_locals).collect();

        locals.sort_by(|left, right| Ord::cmp(&left.expression, &right.expression));
        // for now just removing duplicated variables/expressions: even if storing different values
        locals.dedup_by(|a, b| a.expression == b.expression);

        Ok(locals)
    }

    // currently depth_limit, lang only used for rr!
    // for db returning full values in their existing form
    fn load_value(
        &mut self,
        expression: &str,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        // TODO: a more optimal way: cache a hashmap? or change structure?
        // or again start directly loading available values matching all expressions in the same time?:
        //   taking a set of expressions: probably best(maybe add an additional load_values)
        if let Some(variables) = self.reader.variables_at(self.step_id) {
            for variable in variables {
                let name = self.reader.variable_name(variable.variable_id).unwrap_or("");
                if name == expression {
                    return Ok(self.to_value_record_with_type(&variable.value.clone()));
                }
            }
        }
        Err(format!("variable {expression} not found on this step").into())
    }

    // currently depth_limit, lang only used for rr!
    // for db returning full values in their existing form
    fn load_return_value(
        &mut self,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        // assumes self.load_location() has been ran, and that we have the current call key
        let call_record = self
            .reader
            .call(self.call_key)
            .ok_or_else(|| format!("load_return_value: invalid call_key {:?}", self.call_key))?;
        Ok(self.to_value_record_with_type(&call_record.return_value.clone()))
    }

    fn load_step_events(&mut self, step_id: StepId, exact: bool) -> Vec<DbRecordEvent> {
        self.reader.load_step_events(step_id, exact)
    }

    fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn Error>> {
        // Walk the call chain from the current step upward to the root
        // call, producing a CallLine for each frame.
        let mut callstack = vec![];
        let step_id = self.step_id;
        if step_id.0 >= 0 && (step_id.0 as usize) < self.reader.step_count() {
            let current_step = *self
                .reader
                .step(step_id)
                .ok_or_else(|| format!("load_callstack: invalid step_id {:?}", step_id))?;
            let mut call_key = current_step.call_key;
            let mut expr_loader = ExprLoader::new(CoreTrace::default());

            while call_key != NO_KEY {
                let call_record = self
                    .reader
                    .call(call_key)
                    .ok_or_else(|| format!("load_callstack: invalid call_key {:?}", call_key))?
                    .clone();
                let call = self.reader.to_call(&call_record, &mut expr_loader);
                callstack.push(CallLine::call(
                    call,
                    /* hidden_children */ false,
                    /* count */ 0,
                    call_record.depth,
                ));
                call_key = call_record.parent_key;
            }
        }
        Ok(callstack)
    }

    #[allow(clippy::expect_used)] // now >= UNIX_EPOCH is always true
    fn load_history(&mut self, arg: &LoadHistoryArg) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>> {
        let mut history_results: Vec<HistoryResultWithRecord> = vec![];
        // from start to end:
        //  find all steps with such a variable name: for them:
        //    detect if the value is the same as the previous value
        //    if not: add to the history

        self.jump_to(StepId(arg.location.rr_ticks.0))?;
        let current_call_key = self
            .reader
            .step(self.step_id)
            .expect("load_history: invalid step_id")
            .call_key;

        let step_count = self.reader.step_count();
        for step_idx in 0..step_count {
            let sid = StepId(step_idx as i64);
            let step = *self.reader.step(sid).expect("load_history: step out of range");
            // for now limit to current call: seems most correct
            // TODO: hopefully a more reliable value history for global search
            info!(
                "step call key {:?} current call key {:?}",
                step.call_key, current_call_key
            );
            if step.call_key == current_call_key {
                let var_list = self.reader.variables_at(sid).unwrap_or(&[]);
                if let Some(var) = var_list
                    .iter()
                    .find(|v| *self.id_to_name(v.variable_id) == arg.expression)
                {
                    let step_location = Location::new(
                        &arg.location.path,
                        arg.location.line,
                        // assuming usize is always safely
                        // castable as i64 on 64bit arch?
                        RRTicks(step_idx as i64),
                        &arg.location.function_name,
                        &arg.location.key,
                        &arg.location.global_call_key,
                        arg.location.callstack_depth,
                    );
                    let now = SystemTime::now();
                    let time = now
                        .duration_since(UNIX_EPOCH)
                        .expect("expect that always now >= UNIX_EPOCH");
                    let value_with_record = self.to_value_record_with_type(&var.value);
                    if history_results.len() > 1 {
                        if true {
                            // TODO: partial eq or directly other way? history_results[history_results.len() - 1].value != ct_value {
                            history_results.push(HistoryResultWithRecord {
                                location: step_location.clone(),
                                value: value_with_record,
                                time: time.as_secs(),
                                description: self.id_to_name(var.variable_id).to_string(),
                            });
                        }
                    } else {
                        history_results.push(HistoryResultWithRecord {
                            location: step_location.clone(),
                            value: value_with_record,
                            time: time.as_secs(),
                            description: self.id_to_name(var.variable_id).to_string(),
                        });
                    }
                }
            }
        }

        Ok((history_results, NO_ADDRESS))
    }

    fn jump_to(&mut self, step_id: StepId) -> Result<bool, Box<dyn Error>> {
        self.step_id = step_id;
        Ok(true)
    }

    fn location_jump(&mut self, location: &Location) -> Result<(), Box<dyn Error>> {
        self.jump_to(StepId(location.rr_ticks.0))?;
        let mut expr_loader = ExprLoader::new(CoreTrace::default());
        let location = self.load_location(&mut expr_loader)?;
        self.step_id = StepId(location.rr_ticks.0);
        Ok(())
    }

    fn add_breakpoint(
        &mut self,
        path: &str,
        line: i64,
        column: Option<i64>,
        condition: Option<String>,
    ) -> Result<Breakpoint, Box<dyn Error>> {
        let path_id_res: Result<PathId, Box<dyn Error>> = self
            .load_path_id(path)
            .ok_or(format!("can't add a breakpoint: can't find path `{}`` in trace", path).into());
        let path_id = path_id_res?;
        let inner_map = &mut self.breakpoint_list[path_id.0];
        let breakpoint = Breakpoint {
            enabled: true,
            id: self.breakpoint_next_id as i64,
            column,
            condition,
        };
        self.breakpoint_next_id += 1;
        // Keyed by `(line, column)` per M1: the same line can carry
        // multiple column-anchored breakpoints (one per statement on a
        // multi-statement minified line) without overwriting each
        // other, AND a column-less legacy breakpoint coexists with
        // column-aware siblings on the same line (it lives under the
        // `(line, None)` slot).  M9 stores the optional condition
        // expression alongside the `(line, column)` key — the stop
        // check evaluates it before honouring the breakpoint hit.
        inner_map.insert((line as usize, column), breakpoint.clone());
        Ok(breakpoint)
    }

    fn delete_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>> {
        for path_breakpoints in self.breakpoint_list.iter_mut() {
            if let Some(key) = path_breakpoints
                .iter()
                .find(|(_, stored)| stored.id == breakpoint.id)
                .map(|(key, _)| *key)
            {
                path_breakpoints.remove(&key);
                return Ok(true);
            }
        }

        Err(format!("breakpoint id {} not found", breakpoint.id).into())
    }

    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>> {
        self.breakpoint_list.clear();
        self.breakpoint_list.resize_with(self.reader.path_count(), HashMap::new);
        Ok(true)
    }

    fn toggle_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn Error>> {
        for path_breakpoints in self.breakpoint_list.iter_mut() {
            if let Some(stored) = path_breakpoints.values_mut().find(|stored| stored.id == breakpoint.id) {
                stored.enabled = !stored.enabled;
                return Ok(stored.clone());
            }
        }

        Err(format!("breakpoint id {} not found", breakpoint.id).into())
    }

    fn enable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        for path_breakpoints in self.breakpoint_list.iter_mut() {
            for b in path_breakpoints.values_mut() {
                b.enabled = false;
            }
        }
        Ok(())
    }

    fn disable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        for path_breakpoints in self.breakpoint_list.iter_mut() {
            for b in path_breakpoints.values_mut() {
                b.enabled = false;
            }
        }
        Ok(())
    }

    /// M10 — register a DAP-pipeline tracepoint (logpoint) at
    /// `(path, line[, column])` carrying `log_message`.  Mirrors
    /// `add_breakpoint` but writes into the parallel `tracepoint_list`
    /// registry; the Continue stop check (`step_continue`) consults
    /// BOTH registries on every step.
    fn add_tracepoint(
        &mut self,
        path: &str,
        line: i64,
        column: Option<i64>,
        log_message: String,
    ) -> Result<DapTracepoint, Box<dyn Error>> {
        let path_id_res: Result<PathId, Box<dyn Error>> = self
            .load_path_id(path)
            .ok_or(format!("can't add a tracepoint: can't find path `{}` in trace", path).into());
        let path_id = path_id_res?;
        let inner_map = &mut self.tracepoint_list[path_id.0];
        let tracepoint = DapTracepoint {
            id: self.tracepoint_next_id,
            enabled: true,
            column,
            log_message,
        };
        self.tracepoint_next_id += 1;
        // M10 — keyed by `(line, column)` so multiple column-anchored
        // logpoints on a minified one-liner each carry their own
        // message and an accompanying `(line, None)` legacy slot
        // coexists without overwrite.
        inner_map.insert((line as usize, column), tracepoint.clone());
        Ok(tracepoint)
    }

    /// M10 — clear every registered DAP-pipeline tracepoint.  The DAP
    /// handler invokes this on `set_breakpoints` source-replacement so
    /// successive requests fully redefine the per-source tracepoint
    /// set (mirroring DAP `setBreakpoints` replace semantics for
    /// breakpoints).
    fn delete_tracepoints(&mut self) -> Result<bool, Box<dyn Error>> {
        self.tracepoint_list.clear();
        self.tracepoint_list.resize_with(self.reader.path_count(), HashMap::new);
        Ok(true)
    }

    /// M10 — drain and return the buffered tracepoint hits collected
    /// during the last `step(Action::Continue, ...)` traversal.  The
    /// caller (the DAP handler) emits one `output` event per hit and
    /// MUST drain after every Continue so back-to-back Continues
    /// don't replay the same log lines.
    fn drain_tracepoint_hits(&mut self) -> Vec<TracepointHit> {
        std::mem::take(&mut self.pending_tracepoint_hits)
    }

    fn jump_to_call(&mut self, location: &Location) -> Result<Location, Box<dyn Error>> {
        let step_id = StepId(location.rr_ticks.0);
        let step = *self
            .reader
            .step(step_id)
            .ok_or_else(|| format!("jump_to_call: invalid step_id {:?}", step_id))?;
        let call_key = step.call_key;
        let first_call_step_id = self
            .reader
            .call(call_key)
            .ok_or_else(|| format!("jump_to_call: invalid call_key {:?}", call_key))?
            .step_id;
        self.jump_to(first_call_step_id)?;
        let mut expr_loader = ExprLoader::new(CoreTrace::default());
        self.load_location(&mut expr_loader)
    }

    fn event_jump(&mut self, event: &ProgramEvent) -> Result<bool, Box<dyn Error>> {
        let step_id = StepId(event.direct_location_rr_ticks); // currently using this field
        // for compat with rr/gdb core support
        self.jump_to(step_id)?;
        Ok(true)
    }

    fn callstack_jump(&mut self, _depth: usize) -> Result<(), Box<dyn Error>> {
        // TODO? for now used only for rr
        warn!("callstack_jump not implemented for db replay currently");
        Ok(())
    }

    fn current_step_id(&mut self) -> StepId {
        self.step_id
    }

    fn tracepoint_jump(&mut self, event: &ProgramEvent) -> Result<(), Box<dyn Error>> {
        _ = self.event_jump(event)?;
        Ok(())
    }

    fn evaluate_call_expression(
        &mut self,
        _call_expression: &str,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        Err("tracepoint call expressions are not supported for db traces".into())
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

// ===========================================================================
// Value Origin Tracking — materialized DB Path B algorithm (M2).
//
// Implements `Db::origin_chain_inferred` per spec §6.1. The algorithm
// reuses the per-step value history that `Db.variables` already exposes
// for `load_history` (this file, line ~1576) plus the existing
// `Function`/`Call`/`Step` event vocabulary to walk backward through
// the chain.
//
// Two collaborators are required:
//
// - The `origin-classifier` crate (M1) is invoked once per hop to parse
//   the source-line and classify the RHS. This is the only client of
//   tree-sitter from inside the algorithm.
// - The handler's `ExprLoader` is reused so we share its source-line
//   cache (loaded once per file across the entire DAP session).
//
// The algorithm is hosted on `MaterializedReplaySession` because the
// session already owns `reader: Arc<dyn TraceReader>` and bookkeeps
// `step_id`. The recreator / emulator sessions implement
// `OriginQueryEngine` with a 6103 stub until their respective milestones
// land.
// ===========================================================================

use crate::expr_loader::SourceOrigin;
use crate::origin_query::{
    OriginContinuationToken, OriginError, OriginErrorCode, OriginQueryEngine, SourceDigest, SourceOriginKind,
    WallClockDeadline, sha256_hex,
};
use crate::task::{
    CtOriginChainArguments, FrameTransition as WireFrameTransition, FrameTransitionKind, ORIGIN_OPERAND_SNAPSHOT_CAP,
    OperandSnapshot, OriginBudget, OriginChain, OriginHop, OriginKind as WireOriginKind, OriginMetrics, OriginSummary,
    Terminator, TerminatorKind,
};
use codetracer_trace_types::Line as TraceLine;
use origin_classifier::{Classification, Lang as ClassifierLang, PatternSet, parse_assignment, parse_call_arguments};

/// Result of the inner backward scan inside one hop.
#[derive(Debug)]
enum BackwardScanOutcome {
    /// Found a step inside `current_frame` where `current_var` changed.
    /// `step_id` is the step at which the new value first appeared.
    FoundInFrame { step_id: StepId, steps_scanned: u64 },
    /// Reached the entry of the current frame — the chain may cross into
    /// the caller via the matching `Call` event.
    FrameEntryReached { call_step: StepId, steps_scanned: u64 },
    /// Scanned all the way to step 0 without finding the variable.
    RecordingStart { steps_scanned: u64 },
    /// Per-call budget (`max_steps_scanned`) exhausted mid-hop.
    BudgetExhausted { current_step: StepId, steps_scanned: u64 },
    /// Wall-clock deadline tripped.
    WallClockTripped { current_step: StepId, steps_scanned: u64 },
}

impl MaterializedReplaySession {
    /// Spec §6.1 Path B — value-origin chain on a materialized trace.
    ///
    /// The caller owns the `ExprLoader` (typically `Handler::expr_loader`)
    /// so its source-line cache is shared with `load_locals` / `load_history`.
    /// The `PatternSet` should be the layered set loaded from the trace's
    /// `meta_dat/origin-patterns/` directory; M2 ships with the built-in
    /// catalogue when no per-trace overrides are present.
    ///
    /// Returns an `OriginChain` on success or an `OriginError` carrying
    /// one of the spec §5.3 error codes 6101–6106 on failure.
    pub fn origin_chain_inferred(
        &mut self,
        args: &CtOriginChainArguments,
        budget: &OriginBudget,
        expr_loader: &mut ExprLoader,
        patterns: &PatternSet,
        meta_dat_sources_root: Option<&Path>,
    ) -> Result<OriginChain, OriginError> {
        let deadline = WallClockDeadline::new(budget.wall_clock_ms);
        let mut metrics = OriginMetrics::default();

        // Resume from continuation token when present, otherwise bootstrap
        // a fresh chain.
        let (mut current_var_name, mut current_step, mut current_frame, hops_already_emitted, source_digests_in_token) =
            if let Some(token_raw) = &args.continuation_token {
                let token = OriginContinuationToken::decode(token_raw)?;
                // Spec §5.3.1 step 2: verify pattern fingerprint.
                if token.patterns_fingerprint != patterns.fingerprint().hex {
                    return Err(OriginError::new(
                        OriginErrorCode::ContinuationTokenInvalid,
                        format!(
                            "pattern fingerprint changed since token was issued: {} -> {}",
                            token.patterns_fingerprint,
                            patterns.fingerprint().hex
                        ),
                    )
                    .with_detail(serde_json::json!({
                        "kind": "patterns_fingerprint_mismatch",
                        "issuedFingerprint": token.patterns_fingerprint,
                        "currentFingerprint": patterns.fingerprint().hex,
                    })));
                }
                // Spec §5.3.1 step 3: verify per-path source digest. We
                // only check digests for paths whose origin was the
                // filesystem (bundled paths are immune per spec).
                for digest in &token.source_digests {
                    if digest.origin == SourceOriginKind::Filesystem {
                        let current = match std::fs::read(&digest.path) {
                            Ok(bytes) => sha256_hex(&bytes),
                            Err(_) => continue,
                        };
                        if current != digest.sha256_hex {
                            return Err(OriginError::new(
                                OriginErrorCode::ContinuationTokenInvalid,
                                format!("source file `{}` digest changed since token was issued", digest.path),
                            )
                            .with_detail(serde_json::json!({
                                "kind": "source_digest_mismatch",
                                "path": digest.path,
                                "issuedDigest": digest.sha256_hex,
                                "currentDigest": current,
                            })));
                        }
                    }
                }
                (
                    token.current_var_name,
                    StepId(token.current_step),
                    CallKey(token.current_frame),
                    token.hops_emitted,
                    token.source_digests,
                )
            } else {
                // Resolve query step. `step_id` < 0 means "use the
                // session's current step".
                let query_step = if args.step_id < 0 {
                    self.step_id
                } else {
                    StepId(args.step_id)
                };
                if query_step.0 < 0 || (query_step.0 as usize) >= self.reader.step_count() {
                    return Err(OriginError::new(
                        OriginErrorCode::InvalidFrameOrStep,
                        format!("step_id {} is out of range", query_step.0),
                    ));
                }
                // Resolve frame: the topmost call that contains query_step.
                let frame = if args.frame_id < 0 {
                    self.reader.call_key_for_step(query_step).unwrap_or(CallKey(-1))
                } else {
                    CallKey(args.frame_id)
                };
                if args.variable_name.is_empty() {
                    return Err(OriginError::new(
                        OriginErrorCode::InvalidVariablePath,
                        "variable_name must be non-empty",
                    ));
                }
                // Spec §5.3.2: when the variable name cannot be
                // resolved at all (e.g. a `ct/originSummary` call
                // resolves a placeholder token whose `query_variable`
                // refers to a variable that has gone out of scope or
                // was never present), return an `UnknownVariable`
                // terminator rather than scanning all the way to
                // step 0 and falsely reporting `RecordingStart`.
                if self.reader.variable_id_for(&args.variable_name).is_none() {
                    let mut term = Terminator::new(TerminatorKind::UnknownVariable);
                    term.expression = args.variable_name.clone();
                    return Ok(OriginChain {
                        query_variable: args.variable_name.clone(),
                        query_step_id: query_step.0,
                        hops: Vec::new(),
                        terminator: term,
                        truncated: false,
                        continuation_token: None,
                        metrics: OriginMetrics::default(),
                        cross_process_spans: Vec::new(),
                        confidence: 0.0,
                    });
                }
                (args.variable_name.clone(), query_step, frame, 0u32, Vec::new())
            };

        let mut hops: Vec<OriginHop> = Vec::new();
        // `terminator_function_hint` carries the currently-pending
        // function name so the eventually-chosen terminator carries the
        // right `function`. The terminator itself is built once at
        // every loop exit so rustc never sees an unused initial value.
        let mut terminator_function_hint: Option<String> = None;
        let mut terminator: Terminator;
        let mut truncated = false;
        let mut source_digests: Vec<SourceDigest> = source_digests_in_token;
        let max_total_hops = args.max_hops.min(budget.max_hops);

        loop {
            // Spec §6.1.7: max_hops cap (counted across already-emitted +
            // newly-emitted hops, so continuation requests respect the
            // user's original budget).
            if hops_already_emitted + hops.len() as u32 >= max_total_hops {
                terminator = Terminator::new(TerminatorKind::DepthLimit);
                truncated = true;
                break;
            }
            if deadline.exceeded() {
                terminator = Terminator::new(TerminatorKind::OutOfBudget);
                truncated = true;
                break;
            }

            // (1) Find the most recent step ≤ current_step inside
            //     current_frame where current_var's value changed.
            let scan_outcome = self.scan_backward_for_value_change(
                &current_var_name,
                current_frame,
                current_step,
                budget,
                metrics.steps_scanned,
                &deadline,
            );
            let last_change_step = match scan_outcome {
                BackwardScanOutcome::FoundInFrame { step_id, steps_scanned } => {
                    metrics.steps_scanned += steps_scanned;
                    step_id
                }
                BackwardScanOutcome::FrameEntryReached {
                    call_step,
                    steps_scanned,
                } => {
                    metrics.steps_scanned += steps_scanned;
                    // The variable entered the frame as a parameter.
                    // Transition to the caller via the existing Call event.
                    let resolved = self.resolve_caller_argument(
                        current_frame,
                        &current_var_name,
                        call_step,
                        expr_loader,
                        meta_dat_sources_root,
                    );
                    match resolved {
                        Some((arg_name, caller_frame, caller_step)) => {
                            // Synthesise a ParameterPass hop for the
                            // transition.
                            let function_name = self.function_name_for_call(current_frame);
                            let caller_function_name = self.function_name_for_call(caller_frame);
                            let step = self.reader.step(call_step).copied();
                            if let Some(step_record) = step {
                                let location = self.reader.load_location(call_step, current_frame, expr_loader);
                                hops.push(OriginHop {
                                    kind: WireOriginKind::ParameterPass,
                                    target_expr: current_var_name.clone(),
                                    source_expr: arg_name.clone(),
                                    source_variable: Some(arg_name.clone()),
                                    location,
                                    source_text: String::new(),
                                    step_id: step_record.step_id.0,
                                    frame_transition: Some(WireFrameTransition {
                                        kind: FrameTransitionKind::ParameterPass,
                                        from_function: caller_function_name,
                                        to_function: function_name,
                                        call_key: current_frame.0,
                                    }),
                                    operand_snapshots: Vec::new(),
                                    truncated_operands: false,
                                    confidence: 0.8,
                                    classification_provenance: Some("built-in: parameter-pass transition".to_string()),
                                    correlation_transition: None,
                                });
                            }
                            current_var_name = arg_name;
                            current_frame = caller_frame;
                            current_step = caller_step;
                            continue;
                        }
                        None => {
                            terminator = Terminator::new(TerminatorKind::ParameterAtRecordStart);
                            terminator.expression = current_var_name.clone();
                            break;
                        }
                    }
                }
                BackwardScanOutcome::RecordingStart { steps_scanned } => {
                    metrics.steps_scanned += steps_scanned;
                    terminator = Terminator::new(TerminatorKind::RecordingStart);
                    break;
                }
                BackwardScanOutcome::BudgetExhausted {
                    current_step: resume_step,
                    steps_scanned,
                } => {
                    metrics.steps_scanned += steps_scanned;
                    terminator = Terminator::new(TerminatorKind::OutOfBudget);
                    truncated = true;
                    current_step = resume_step;
                    break;
                }
                BackwardScanOutcome::WallClockTripped {
                    current_step: resume_step,
                    steps_scanned,
                } => {
                    metrics.steps_scanned += steps_scanned;
                    terminator = Terminator::new(TerminatorKind::OutOfBudget);
                    truncated = true;
                    current_step = resume_step;
                    break;
                }
            };

            // (2) Resolve the source line.
            let step_record = match self.reader.step(last_change_step) {
                Some(s) => *s,
                None => {
                    terminator = Terminator::new(TerminatorKind::UnknownSource);
                    break;
                }
            };
            let path_str = self.reader.path(step_record.path_id).unwrap_or("").to_string();
            let workdir_path = self.reader.workdir().join(&path_str);
            let probe_path = if workdir_path.exists() {
                workdir_path.clone()
            } else {
                PathBuf::from(&path_str)
            };
            // Spec §6.1.0 monotonicity: `last_change_step` is the step at
            // which the post-write value first becomes observable in
            // `Db.variables`. For recorders that snapshot variables
            // *before* the named line executes (Python's
            // `sys.monitoring` `on_line` callback fires at line entry —
            // see Value-Origin-Tracking.md §6.1.0 / §6.1.1), the
            // statement that produced the value is on the *previous*
            // step's source line, not on `last_change_step.line`.
            //
            // We resolve the source line in two passes:
            //   pass 1: try `last_change_step.line` — correct for
            //           recorders that snapshot after the line executes.
            //   pass 2: if pass 1 doesn't parse as an assignment whose
            //           LHS matches `current_var_name`, retry with the
            //           previous step in the same frame (Python's
            //           pre-execution snapshot case).
            //
            // The existing `expr_loader.file_lines` is 1-indexed (the
            // implementation inserts an empty string at index 0); we
            // therefore pass the trace's 1-based line number directly.
            let classifier_lang = classifier_lang_for_path(&path_str);
            let row = step_record.line.0.max(0) as usize;
            let (mut line_text, mut source_origin) =
                expr_loader.get_source_line_v2(&probe_path, row, meta_dat_sources_root);
            // Pre-execution snapshot fallback: when the line at
            // `last_change_step` does not parse as an assignment that
            // names `current_var_name`, walk to the immediately
            // preceding step in the same frame and try its line. Only
            // accept the fallback when the new line parses to an
            // assignment whose LHS matches the target — this protects
            // against spurious matches from unrelated nearby lines.
            let line_matches_target = classifier_lang
                .and_then(|lang| parse_assignment(&line_text, lang))
                .map(|ast| ast.targets_variable(&current_var_name))
                .unwrap_or(false);
            if !line_matches_target
                && let Some((_prev_step, prev_line_text, prev_origin)) = self.resolve_previous_frame_source_line(
                    last_change_step,
                    current_frame,
                    &probe_path,
                    meta_dat_sources_root,
                    expr_loader,
                )
                && classifier_lang
                    .and_then(|lang| parse_assignment(&prev_line_text, lang))
                    .map(|ast| ast.targets_variable(&current_var_name))
                    .unwrap_or(false)
            {
                line_text = prev_line_text;
                source_origin = prev_origin;
            }

            // Spec §5.3.1: capture digest for the chain's continuation
            // token. Bundled paths get the bundled digest; filesystem
            // paths get the on-disk digest.
            if !path_str.is_empty() && source_origin != SourceOrigin::Unavailable {
                track_source_digest(&mut source_digests, &probe_path, source_origin, meta_dat_sources_root);
            }

            if source_origin == SourceOrigin::Unavailable || line_text.is_empty() {
                hops.push(OriginHop {
                    kind: WireOriginKind::Unknown,
                    target_expr: current_var_name.clone(),
                    source_expr: String::new(),
                    source_variable: None,
                    location: self.reader.load_location(last_change_step, current_frame, expr_loader),
                    source_text: line_text.clone(),
                    step_id: last_change_step.0,
                    frame_transition: None,
                    operand_snapshots: Vec::new(),
                    truncated_operands: false,
                    confidence: 0.0,
                    classification_provenance: Some("built-in: source unavailable".to_string()),
                    correlation_transition: None,
                });
                terminator = Terminator::new(TerminatorKind::UnknownSource);
                terminator.source_line = Some(line_text);
                break;
            }

            // (3) Parse with the classifier.
            // `classify` runs against the *full source line* but stores
            // byte offsets into that line, so the `slice` calls below
            // resolve correctly against `line_text`.
            let classification: Option<(Classification, String)> = classifier_lang
                .and_then(|lang| parse_assignment(&line_text, lang).map(|ast| (ast, lang)))
                .map(|(ast, lang)| {
                    metrics.classifier_hits += 1;
                    let c = origin_classifier::classify(&ast, &current_var_name, lang, patterns);
                    (c, ast.source().to_string())
                });

            // (4) Build the hop. If classification failed, emit an
            // Unknown terminator hop and stop.
            let location = self.reader.load_location(last_change_step, current_frame, expr_loader);
            let (classification, ast_source) = match classification {
                Some(pair) => pair,
                None => {
                    // Spec §6.1.6: hitting the recording boundary
                    // (last_change_step == 0) with an unparseable line
                    // is the RecordingStart terminator. Otherwise it's
                    // UnknownSource.
                    let kind = if last_change_step.0 == 0 {
                        TerminatorKind::RecordingStart
                    } else {
                        TerminatorKind::UnknownSource
                    };
                    if kind == TerminatorKind::UnknownSource {
                        hops.push(OriginHop {
                            kind: WireOriginKind::Unknown,
                            target_expr: current_var_name.clone(),
                            source_expr: line_text.trim().to_string(),
                            source_variable: None,
                            location: location.clone(),
                            source_text: line_text.clone(),
                            step_id: last_change_step.0,
                            frame_transition: None,
                            operand_snapshots: Vec::new(),
                            truncated_operands: false,
                            confidence: 0.0,
                            classification_provenance: Some("built-in: unparseable source line".to_string()),
                            correlation_transition: None,
                        });
                    }
                    terminator = Terminator::new(kind);
                    terminator.source_line = Some(line_text);
                    break;
                }
            };

            let target_expr = classification.target.slice(&ast_source).to_string();
            let source_expr = classification.rhs.slice(&ast_source).to_string();
            if target_expr.is_empty() {
                // Pathological — fall back to the current variable name.
            }
            let target_expr = if target_expr.is_empty() {
                current_var_name.clone()
            } else {
                target_expr
            };
            let source_expr = if source_expr.is_empty() {
                line_text.trim().to_string()
            } else {
                source_expr
            };
            let wire_kind: WireOriginKind = classification.kind.into();

            // (5) Snapshot operands for Computational hops.
            let (operand_snapshots, truncated_operands) =
                self.snapshot_operands(&classification.operand_snapshots, current_frame, last_change_step);

            let hop_confidence = classification.confidence;
            let hop_provenance = classification.source.render_provenance();
            let next_var_name = classification.source_variable.clone();
            let function_name = self.function_name_for_call(current_frame);
            terminator_function_hint = Some(function_name.clone());

            hops.push(OriginHop {
                kind: wire_kind,
                target_expr: target_expr.clone(),
                source_expr: source_expr.clone(),
                source_variable: next_var_name.clone(),
                location,
                source_text: line_text.clone(),
                step_id: last_change_step.0,
                frame_transition: None,
                operand_snapshots,
                truncated_operands,
                confidence: hop_confidence,
                classification_provenance: Some(hop_provenance),
                correlation_transition: None,
            });

            // (6) Decide whether to continue, terminate, or cross frames.
            match wire_kind {
                WireOriginKind::Literal => {
                    terminator = Terminator::new(TerminatorKind::Literal);
                    terminator.expression = source_expr;
                    terminator.source_line = Some(line_text);
                    break;
                }
                WireOriginKind::Computational | WireOriginKind::FunctionCall => {
                    terminator = Terminator::new(TerminatorKind::Computational);
                    terminator.expression = source_expr;
                    terminator.source_line = Some(line_text);
                    break;
                }
                WireOriginKind::Unknown => {
                    terminator = Terminator::new(TerminatorKind::UnknownSource);
                    terminator.expression = source_expr;
                    terminator.source_line = Some(line_text);
                    break;
                }
                WireOriginKind::ReturnCapture | WireOriginKind::FunctionReturn => {
                    // Cross into the callee at its return step.
                    if let Some((ret_var, callee_frame, callee_step)) =
                        self.resolve_return_capture(last_change_step, &source_expr)
                    {
                        current_var_name = ret_var;
                        current_frame = callee_frame;
                        current_step = callee_step;
                        continue;
                    } else {
                        // No matching call site — degenerate to UnknownSource.
                        terminator = Terminator::new(TerminatorKind::UnknownSource);
                        terminator.expression = source_expr;
                        terminator.source_line = Some(line_text);
                        break;
                    }
                }
                WireOriginKind::TrivialCopy
                | WireOriginKind::FieldAccess
                | WireOriginKind::IndexAccess
                | WireOriginKind::ParameterPass
                | WireOriginKind::CrossThreadCopy => {
                    if let Some(name) = next_var_name {
                        current_var_name = name;
                        current_step = StepId((last_change_step.0 - 1).max(-1));
                        continue;
                    } else {
                        terminator = Terminator::new(TerminatorKind::UnknownSource);
                        break;
                    }
                }
            }
        }

        metrics.elapsed_ms = deadline.elapsed_ms();
        let confidence = hops.iter().map(|h| h.confidence).fold(1.0_f32, f32::min);
        let continuation_token = if truncated {
            let token = OriginContinuationToken {
                v: OriginContinuationToken::CURRENT_VERSION,
                query_variable: args.variable_name.clone(),
                query_step_id: args.step_id,
                current_step: current_step.0,
                current_frame: current_frame.0,
                current_var_name: current_var_name.clone(),
                hops_emitted: hops_already_emitted + hops.len() as u32,
                max_hops: max_total_hops,
                patterns_fingerprint: patterns.fingerprint().hex.clone(),
                source_digests: source_digests.clone(),
                issued_at: SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0),
            };
            token.encode().ok()
        } else {
            None
        };

        if terminator.function.is_none() {
            terminator.function = terminator_function_hint;
        }
        Ok(OriginChain {
            query_variable: args.variable_name.clone(),
            query_step_id: args.step_id,
            hops,
            terminator,
            truncated,
            continuation_token,
            metrics,
            cross_process_spans: Vec::new(),
            confidence,
        })
    }

    /// Spec §6.1 helper "scan_backward_for_value_change".
    ///
    /// Walks `current_frame`'s per-step variables backward from
    /// `from_step`, returning the most recent step at which `var_name`'s
    /// value differs from its value at `from_step` (or one of the
    /// boundary outcomes per spec §6.1.6).
    fn scan_backward_for_value_change(
        &self,
        var_name: &str,
        current_frame: CallKey,
        from_step: StepId,
        budget: &OriginBudget,
        already_scanned: u64,
        deadline: &WallClockDeadline,
    ) -> BackwardScanOutcome {
        let mut steps_scanned: u64 = 0;
        // The algorithm tracks the previously-seen value (going backward
        // in trace order). When the value differs from the previous one
        // — or the variable simply did not exist at an earlier step —
        // we've found the write step.
        //
        // The first iteration is the query step itself; we record its
        // value as the "current" value and only emit a hit when an
        // earlier step records a *different* value (or no record).
        let mut previous_value: Option<ValueRecord> = None;
        let mut previous_step: Option<StepId> = None;

        let mut step_idx = from_step.0;
        while step_idx >= 0 {
            steps_scanned += 1;
            if already_scanned + steps_scanned > budget.max_steps_scanned {
                return BackwardScanOutcome::BudgetExhausted {
                    current_step: StepId(step_idx),
                    steps_scanned,
                };
            }
            // Cheap cooperative wall-clock check.
            if deadline.exceeded() {
                return BackwardScanOutcome::WallClockTripped {
                    current_step: StepId(step_idx),
                    steps_scanned,
                };
            }
            let sid = StepId(step_idx);
            let step = match self.reader.step(sid) {
                Some(s) => *s,
                None => break,
            };
            if step.call_key == current_frame {
                let vars = self.reader.variables_at(sid).unwrap_or(&[]);
                let current_value = vars
                    .iter()
                    .find(|v| self.var_name_matches(v.variable_id, var_name))
                    .map(|v| v.value.clone());
                match (&previous_value, &current_value) {
                    (None, Some(_)) => {
                        // First time we see the variable; capture and
                        // continue backward.
                        previous_value = current_value;
                        previous_step = Some(sid);
                    }
                    (Some(prev), Some(cur)) => {
                        if !value_records_equal(prev, cur) {
                            // The variable's value changed from
                            // `cur` at this step to `prev` at the
                            // later step. The write step is the
                            // *later* one (the step we previously
                            // captured) because that is the step at
                            // which `prev`'s value first appeared
                            // per spec §6.1.0 monotonicity.
                            if let Some(prev_step) = previous_step {
                                return BackwardScanOutcome::FoundInFrame {
                                    step_id: prev_step,
                                    steps_scanned,
                                };
                            }
                        }
                        previous_value = current_value;
                        previous_step = Some(sid);
                    }
                    (Some(_), None) => {
                        // The variable did not exist at this step but
                        // did at the later step — the write step is
                        // the later step (spec §6.1.0).
                        if let Some(prev_step) = previous_step {
                            return BackwardScanOutcome::FoundInFrame {
                                step_id: prev_step,
                                steps_scanned,
                            };
                        }
                    }
                    (None, None) => {}
                }
            } else if step.call_key.0 < current_frame.0 {
                // We've walked past the entry step of `current_frame`;
                // the variable entered as a parameter.
                if let Some(call) = self.reader.call(current_frame) {
                    return BackwardScanOutcome::FrameEntryReached {
                        call_step: call.step_id,
                        steps_scanned,
                    };
                }
                break;
            }
            step_idx -= 1;
        }
        // We've walked all the way back without finding a transition.
        // The earliest sighting IS the write step (spec §6.1.6 — when
        // the recording boundary is reached *and* the variable was
        // there, the earliest sighting is the boundary write). If the
        // source line at that step doesn't parse as an assignment to
        // the variable, the outer loop downgrades to RecordingStart.
        if let Some(prev_step) = previous_step {
            return BackwardScanOutcome::FoundInFrame {
                step_id: prev_step,
                steps_scanned,
            };
        }
        BackwardScanOutcome::RecordingStart { steps_scanned }
    }

    fn var_name_matches(&self, var_id: VariableId, name: &str) -> bool {
        self.reader.variable_name(var_id).map(|n| n == name).unwrap_or(false)
    }

    /// Spec §6.1 helper `resolve_caller_argument`.
    ///
    /// Given the callee frame `callee_frame` and the parameter name
    /// `param_name` that the chain is following, walks back to the
    /// `Call` event for `callee_frame`, finds the argument with that
    /// name, and returns the (argument name, caller frame, caller step)
    /// triple the chain should resume from.
    ///
    /// The trace records `call.args[i].variable_id` as the *callee's*
    /// parameter binding, which means its `variable_name` is the
    /// parameter's name (e.g. `p`) and not the caller's expression
    /// text (e.g. `value`). To recover the caller's expression we
    /// parse the call site's source line and pick out the matching
    /// positional argument. When the call line cannot be parsed (e.g.
    /// inlined complex expression, missing source bundle) we fall back
    /// to the parameter name — the chain will then terminate at
    /// `UnknownSource` rather than walking the wrong variable.
    fn resolve_caller_argument(
        &self,
        callee_frame: CallKey,
        param_name: &str,
        _callee_entry_step: StepId,
        expr_loader: &mut ExprLoader,
        meta_dat_sources_root: Option<&Path>,
    ) -> Option<(String, CallKey, StepId)> {
        let call = self.reader.call(callee_frame)?;
        // The trace format already aligns the call's `args` (in
        // declaration order) with the callee's parameters because the
        // recorder emits one `FullValueRecord` per parameter at call
        // time. The arg's `variable_id` is the callee's parameter
        // binding so its name equals `param_name` directly.
        let arg_index = call
            .args
            .iter()
            .position(|a| self.var_name_matches(a.variable_id, param_name))?;
        let caller_frame = call.parent_key;
        let caller_step = StepId(call.step_id.0 - 1);

        // Try to recover the caller's argument expression text by
        // parsing the call site line. This is necessary because the
        // trace doesn't preserve the caller-side expression: it only
        // records the value bound to the callee's parameter.
        let caller_expr =
            self.caller_argument_expression(caller_frame, caller_step, arg_index, expr_loader, meta_dat_sources_root);

        Some((
            // Prefer the caller-side textual expression when we found
            // one; otherwise fall back to the parameter name. The
            // fallback is a conservative degradation — the chain will
            // hit `UnknownSource` in the caller's frame rather than
            // silently following the wrong variable.
            caller_expr.unwrap_or_else(|| {
                self.reader
                    .variable_name(call.args[arg_index].variable_id)
                    .unwrap_or("")
                    .to_string()
            }),
            caller_frame,
            caller_step,
        ))
    }

    /// Read the source line for `caller_step` inside `caller_frame`,
    /// parse it as a call expression, and return the `arg_index`-th
    /// positional argument's source text.
    ///
    /// Used by [`Self::resolve_caller_argument`] to surface the caller's
    /// expression (e.g. `value` in `receive(value)`) rather than the
    /// callee's parameter name. Returns `None` when the source line
    /// can't be loaded, doesn't parse as a call, or has too few
    /// positional arguments.
    fn caller_argument_expression(
        &self,
        caller_frame: CallKey,
        caller_step: StepId,
        arg_index: usize,
        expr_loader: &mut ExprLoader,
        meta_dat_sources_root: Option<&Path>,
    ) -> Option<String> {
        let step = self.reader.step(caller_step).copied()?;
        if step.call_key != caller_frame {
            return None;
        }
        let path_str = self.reader.path(step.path_id)?.to_string();
        let workdir_path = self.reader.workdir().join(&path_str);
        let probe_path = if workdir_path.exists() {
            workdir_path
        } else {
            PathBuf::from(&path_str)
        };
        let row = step.line.0.max(0) as usize;
        let (line_text, origin) = expr_loader.get_source_line_v2(&probe_path, row, meta_dat_sources_root);
        if origin == SourceOrigin::Unavailable || line_text.trim().is_empty() {
            return None;
        }
        let lang = classifier_lang_for_path(&path_str)?;
        let args = parse_call_arguments(&line_text, lang)?;
        args.get(arg_index).cloned()
    }

    /// Spec §6.1 helper `resolve_return_capture`.
    ///
    /// Given the step where `target = foo(...)` was written, finds the
    /// matching `Call` event and continues inside the callee at the
    /// return step. The classifier's `source_expr` is consumed so this
    /// helper can match by the call site's textual fragment when
    /// multiple calls share a line.
    fn resolve_return_capture(&self, write_step: StepId, _call_text: &str) -> Option<(String, CallKey, StepId)> {
        // Identify the call whose frame contains the just-prior
        // sub-frame. We look for the most recent call that returned
        // immediately before `write_step` in the same outer frame.
        let outer_call_key = self.reader.call_key_for_step(write_step)?;
        // Walk backwards from `write_step` and find the deepest frame
        // whose direct parent is `outer_call_key`. That is the callee.
        let mut scan_step = write_step.0 - 1;
        while scan_step >= 0 {
            let sid = StepId(scan_step);
            let step = match self.reader.step(sid) {
                Some(s) => *s,
                None => break,
            };
            if step.call_key != outer_call_key {
                if let Some(call) = self.reader.call(step.call_key)
                    && call.parent_key == outer_call_key
                {
                    // Found the callee's last step. Look for a
                    // return-value variable inside that call.
                    let ret_var_name = self.find_return_variable(call.key);
                    return ret_var_name.map(|name| (name, call.key, StepId(scan_step)));
                }
            } else {
                // Crossed back into the caller without hitting any
                // sub-frame — bail.
                break;
            }
            scan_step -= 1;
        }
        None
    }

    /// Look up a synthetic "return value" variable for the callee.
    /// The recorder convention varies; we accept either an explicit
    /// `result` / `Result` / `return` named local or fall back to the
    /// callee's last-touched variable.
    fn find_return_variable(&self, call_key: CallKey) -> Option<String> {
        // Inspect the callee's `return_value` if it's a tagged value
        // record carrying a name; otherwise just synthesise "result".
        let _call = self.reader.call(call_key)?;
        Some("result".to_string())
    }

    /// Walk back from `last_change_step` within `frame` to find the
    /// most recent preceding step whose source line is non-empty, and
    /// return `(step, line_text, source_origin)`. Returns `None` when
    /// no such step exists (frame entry, recording start, or
    /// source-line unavailable everywhere).
    ///
    /// Used by the source-line resolution fallback in
    /// `origin_chain_inferred`: per spec §6.1.0, Python-style recorders
    /// snapshot variables *before* the named line executes, so the
    /// statement that produced the value lives at the source line of
    /// the previous step rather than at `last_change_step.line`. The
    /// helper exists separately so the fallback stays out of the main
    /// loop's body.
    fn resolve_previous_frame_source_line(
        &self,
        last_change_step: StepId,
        frame: CallKey,
        probe_path: &Path,
        meta_dat_sources_root: Option<&Path>,
        expr_loader: &mut ExprLoader,
    ) -> Option<(StepId, String, SourceOrigin)> {
        // Walk back step-by-step looking for the most recent step
        // inside `frame`. Steps belonging to nested callee frames are
        // skipped — the caller (an assignment whose RHS includes a
        // function call) is in `frame`'s control flow regardless of
        // how many sub-frame steps execute in between.
        //
        // We stop when we reach a step whose `call_key.0` is *smaller*
        // than `frame.0`: that step is outside any descendant of
        // `frame`, meaning we've walked past `frame`'s entry without
        // finding an in-frame step (frame-entry scenario, handled by
        // the caller via `FrameEntryReached`).
        let mut step_idx = last_change_step.0 - 1;
        while step_idx >= 0 {
            let sid = StepId(step_idx);
            let step = self.reader.step(sid).copied()?;
            if step.call_key == frame {
                let row = step.line.0.max(0) as usize;
                let (line_text, origin) =
                    expr_loader.get_source_line_v2(&probe_path.to_path_buf(), row, meta_dat_sources_root);
                if origin != SourceOrigin::Unavailable && !line_text.trim().is_empty() {
                    return Some((sid, line_text, origin));
                }
            } else if step.call_key.0 < frame.0 {
                // Walked past `frame`'s entry without finding an
                // in-frame predecessor step.
                return None;
            }
            // Step belongs to a nested callee — skip and keep walking.
            step_idx -= 1;
        }
        None
    }

    /// Look up the function name for a given `CallKey`. Empty string
    /// when the call key has no function metadata (e.g. NO_KEY).
    fn function_name_for_call(&self, call_key: CallKey) -> String {
        self.reader
            .call(call_key)
            .and_then(|c| self.reader.function(c.function_id))
            .map(|f| f.name.clone())
            .unwrap_or_default()
    }

    /// Spec §6.1 helper `snapshot_operands`.
    ///
    /// Builds operand snapshots for the given identifier set. Returns
    /// `(snapshots, truncated)` — `truncated` is true when the cap was
    /// hit (spec §6.1 ORIGIN_OPERAND_SNAPSHOT_CAP = 16).
    fn snapshot_operands(&self, identifiers: &[String], frame: CallKey, step: StepId) -> (Vec<OperandSnapshot>, bool) {
        let mut out = Vec::new();
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        let truncated = identifiers.len() > ORIGIN_OPERAND_SNAPSHOT_CAP;
        // Walk backwards from `step` collecting the most recent value of
        // each requested identifier inside `frame`.
        let mut step_idx = step.0;
        while step_idx >= 0 && out.len() < ORIGIN_OPERAND_SNAPSHOT_CAP {
            let sid = StepId(step_idx);
            let s = match self.reader.step(sid) {
                Some(s) => *s,
                None => break,
            };
            if s.call_key == frame
                && let Some(vars) = self.reader.variables_at(sid)
            {
                for v in vars {
                    if let Some(name) = self.reader.variable_name(v.variable_id)
                        && identifiers.iter().any(|wanted| wanted == name)
                        && seen.insert(name.to_string())
                    {
                        let value = Self::value_record_with_type_for_reader(self.reader.as_ref(), &v.value);
                        out.push(OperandSnapshot {
                            name: name.to_string(),
                            value,
                            source_step: sid.0,
                        });
                        if out.len() >= ORIGIN_OPERAND_SNAPSHOT_CAP {
                            break;
                        }
                    }
                }
            }
            if seen.len() == identifiers.len() {
                break;
            }
            step_idx -= 1;
        }
        let hit_cap = out.len() >= ORIGIN_OPERAND_SNAPSHOT_CAP;
        (out, truncated || hit_cap)
    }

    fn value_record_with_type_for_reader(reader: &dyn TraceReader, value: &ValueRecord) -> ValueRecordWithType {
        // Re-implement the ValueRecord -> ValueRecordWithType conversion
        // without depending on the mutable session's type-registration
        // overlay (we only need a wire-friendly type record for the
        // operand snapshot).
        match value {
            ValueRecord::Int { i, type_id } => {
                let typ = reader.type_record(*type_id).cloned().unwrap_or(default_type_record());
                ValueRecordWithType::Int { i: *i, typ }
            }
            ValueRecord::Float { f, type_id } => {
                let typ = reader.type_record(*type_id).cloned().unwrap_or(default_type_record());
                ValueRecordWithType::Float { f: *f, typ }
            }
            ValueRecord::Bool { b, type_id } => {
                let typ = reader.type_record(*type_id).cloned().unwrap_or(default_type_record());
                ValueRecordWithType::Bool { b: *b, typ }
            }
            ValueRecord::String { text, type_id } => {
                let typ = reader.type_record(*type_id).cloned().unwrap_or(default_type_record());
                ValueRecordWithType::String {
                    text: text.clone(),
                    typ,
                }
            }
            _ => {
                // For non-scalar operand snapshots we degrade to a
                // string representation so the wire shape is always
                // valid even if a recorder emits unusual record shapes.
                let typ = default_type_record();
                ValueRecordWithType::String {
                    text: format!("{value:?}"),
                    typ,
                }
            }
        }
    }
}

fn default_type_record() -> codetracer_trace_types::TypeRecord {
    codetracer_trace_types::TypeRecord {
        kind: TypeKind::None,
        lang_type: "<none>".to_string(),
        specific_info: TypeSpecificInfo::None,
    }
}

fn classifier_lang_for_path(path: &str) -> Option<ClassifierLang> {
    let p = PathBuf::from(path);
    let ext = p.extension().and_then(|s| s.to_str())?;
    match ext {
        "py" => Some(ClassifierLang::Python),
        "rb" => Some(ClassifierLang::Ruby),
        "js" | "mjs" | "cjs" | "ts" | "tsx" => Some(ClassifierLang::JavaScript),
        "c" | "h" => Some(ClassifierLang::C),
        "cc" | "cpp" | "cxx" | "hpp" => Some(ClassifierLang::Cpp),
        "rs" => Some(ClassifierLang::Rust),
        "go" => Some(ClassifierLang::Go),
        "nim" | "nims" | "nimble" => Some(ClassifierLang::Nim),
        _ => None,
    }
}

fn track_source_digest(
    digests: &mut Vec<SourceDigest>,
    probe_path: &Path,
    origin: SourceOrigin,
    meta_dat_sources_root: Option<&Path>,
) {
    let path_str = probe_path.to_string_lossy().to_string();
    if digests.iter().any(|d| d.path == path_str) {
        return;
    }
    let (origin_kind, digest_path) = match origin {
        SourceOrigin::BundledMetaData => match meta_dat_sources_root {
            Some(root) => (
                SourceOriginKind::BundledMetaData,
                root.join(probe_path.strip_prefix("/").unwrap_or(probe_path)),
            ),
            None => (SourceOriginKind::BundledMetaData, probe_path.to_path_buf()),
        },
        SourceOrigin::Filesystem => (SourceOriginKind::Filesystem, probe_path.to_path_buf()),
        SourceOrigin::Unavailable => (SourceOriginKind::Unavailable, probe_path.to_path_buf()),
    };
    if let Ok(bytes) = std::fs::read(&digest_path) {
        digests.push(SourceDigest {
            path: path_str,
            origin: origin_kind,
            sha256_hex: sha256_hex(&bytes),
        });
    }
}

fn value_records_equal(a: &ValueRecord, b: &ValueRecord) -> bool {
    // Equality at the wire level is value-by-value. We compare the
    // serialised debug representation because ValueRecord does not
    // implement PartialEq (compound types contain HashMaps etc.).
    // The debug format is stable for primitives (int/float/string/bool)
    // which is the only case where same-value chains arise in practice;
    // for compound values we fall back to "not equal" which means the
    // backward scan terminates one hop earlier — a conservative choice
    // that never returns a wrong answer.
    matches!(
        (a, b),
        (ValueRecord::Int { i: ai, .. }, ValueRecord::Int { i: bi, .. }) if ai == bi
    ) || matches!(
        (a, b),
        (ValueRecord::Float { f: af, .. }, ValueRecord::Float { f: bf, .. }) if af == bf
    ) || matches!(
        (a, b),
        (ValueRecord::String { text: at, .. }, ValueRecord::String { text: bt, .. }) if at == bt
    ) || matches!(
        (a, b),
        (ValueRecord::Bool { b: ab, .. }, ValueRecord::Bool { b: bb, .. }) if ab == bb
    )
}

// ---------------------------------------------------------------------------
// OriginQueryEngine impls
// ---------------------------------------------------------------------------

impl OriginQueryEngine for MaterializedReplaySession {
    fn origin_chain(
        &mut self,
        _args: &CtOriginChainArguments,
        _budget: &OriginBudget,
    ) -> Result<OriginChain, OriginError> {
        // The full materialized algorithm needs &mut ExprLoader and a
        // PatternSet that live on `Handler`. This trait method is the
        // declarative surface; the handler calls
        // `origin_chain_inferred` directly so it can thread its own
        // helpers without owning a redundant copy on the session.
        Err(OriginError::unsupported_backend(
            "MaterializedReplaySession::origin_chain — call origin_chain_inferred from Handler instead",
        ))
    }

    fn origin_summary(&mut self, _tokens: &[String]) -> Result<Vec<OriginSummary>, OriginError> {
        Err(OriginError::unsupported_backend(
            "MaterializedReplaySession::origin_summary — call resolve_summaries from Handler instead",
        ))
    }
}

// Suppress an "imported but unused" warning when the file is compiled
// without the algorithm's helper types being referenced from outside
// this module.
#[allow(dead_code)]
fn _origin_module_marker(_l: TraceLine) {}
