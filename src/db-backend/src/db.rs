use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use num_bigint::BigInt;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::error::Error;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use std::vec::Vec;

use log::{error, info, warn};
use runtime_tracing::{
    CallKey, EventLogKind, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, Place, StepId, TypeId, TypeKind,
    TypeRecord, TypeSpecificInfo, ValueRecord, VariableId, NO_KEY,
};

use crate::distinct_vec::DistinctVec;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
use crate::replay::Replay;
use crate::task::{
    Action, Breakpoint, Call, CallArg, CallLine, CoreTrace, CtLoadLocalsArguments, CtLoadMemoryRangeArguments,
    CtLoadMemoryRangeResponseBody, Events, HistoryResultWithRecord, LoadHistoryArg, Location, MemoryRangeState,
    ProgramEvent, RRTicks, VariableWithRecord, NO_ADDRESS, NO_INDEX, NO_PATH, NO_POSITION,
};
use crate::value::{Type, Value, ValueRecordWithType};

const NEXT_INTERNAL_STEP_OVERS_LIMIT: usize = 1_000;
const MAX_MEMORY_RANGE_BYTES: i64 = 4 * 1024 * 1024;

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

        assert!(call_key_int >= 0);

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
                    location.function_first = fn_start;
                    location.function_last = fn_last;
                }
                Err(e) => {
                    warn!("expr loader load file error: {e:?}");
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
        let mut last_step_id = step_id;
        let original_step = self.steps[step_id];
        let (original_path_id, original_line, original_call_key) =
            (original_step.path_id, original_step.line, original_step.call_key);
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
            if !step_to_different_line {
                break;
            } else {
                let current_step = self.steps[current_step_id];
                if original_path_id != current_step.path_id
                    || original_line != current_step.line
                    || original_call_key != current_step.call_key
                {
                    // this is a different line: or even if the same line, it's in a different call!
                    break;
                }
            }
        }
        info!("next step id: {:?}", self.steps[last_step_id]);
        (last_step_id, step_id != last_step_id)
    }

    // returns the new step id and if a limit(first or last step) of the record is reached
    pub fn step_out_step_id_relative_to(&self, step_id: StepId, forward: bool) -> (StepId, bool) {
        // depth = 1 => we target upper level
        let new_step_id = self.step_over_depths_step_id(step_id, forward, 1);
        (new_step_id, step_id != new_step_id)
    }

    pub fn step_over_depths_step_id(&self, start_step_id: StepId, forward: bool, delta: usize) -> StepId {
        let initial_step = &self.steps[start_step_id];
        let initial_call = &self.calls[initial_step.call_key];
        let initial_call_depth = initial_call.depth;
        let mut current_step_id = start_step_id;

        for new_step in self.step_from(start_step_id, forward) {
            // while !self.on_step_id_limit(i, forward) {
            // info!("next:i: {}", i);
            // i = self.single_step_line(i, forward);
            // let new_step = &self.db.steps[i];
            let new_call_key = new_step.call_key;
            current_step_id = new_step.step_id;
            let new_call = &self.calls[new_call_key];

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
        if self.types.len() == 0 {
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
        if !exact {
            let original_step = self.steps[step_id];
            let original_path_id = original_step.path_id;
            let original_line = original_step.line;
            let mut current_step_id = step_id + 1;
            while (current_step_id.0 as usize) < self.steps.len() {
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
        if self.forward {
            // moving forward
            self.step_id.0 as usize >= self.db.steps.len() - 1 // we're on the last one
        } else {
            // moving backwards
            self.step_id.0 as usize == 0
        }
    }

    fn single_step_line(&self) -> StepId {
        // taking note of db.lines limits: returning a valid step id always
        if self.forward {
            assert!((self.step_id.0 as usize) < self.db.steps.len() - 1);
            self.step_id + 1
        } else {
            assert!(self.step_id.0 as usize > 0);
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

#[derive(Debug)]
pub struct DbReplay {
    // to optimize and prevents problems with too many `.clone()`
    //   currently mostly in flow;
    //   we can try to share a readonly version: `Rc`? `RefCell`?
    //   or we can leave it like this for now and expect that the new format
    //   will deal with that?
    pub db: Box<Db>,
    pub step_id: StepId,
    pub call_key: CallKey,
    pub breakpoint_list: Vec<HashMap<usize, Breakpoint>>,
    breakpoint_next_id: usize,
}

impl DbReplay {
    pub fn new(db: Box<Db>) -> DbReplay {
        let mut breakpoint_list: Vec<HashMap<usize, Breakpoint>> = Default::default();
        breakpoint_list.resize_with(db.paths.len(), HashMap::new);
        DbReplay {
            db,
            step_id: StepId(0),
            call_key: CallKey(0),
            breakpoint_list,
            breakpoint_next_id: 0,
        }
    }

    pub fn register_type(&mut self, typ: TypeRecord) -> TypeId {
        // for no checking for typ.name logic: eventually in ensure_type?
        self.db.types.push(typ);
        TypeId(self.db.types.len() - 1)
    }

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
        }
    }

    pub fn to_value_record_with_type(&self, v: &ValueRecord) -> ValueRecordWithType {
        match v {
            ValueRecord::Int { i, type_id } => ValueRecordWithType::Int {
                i: *i,
                typ: self.db.types[*type_id].clone(),
            },
            ValueRecord::Float { f, type_id } => ValueRecordWithType::Float {
                f: *f,
                typ: self.db.types[*type_id].clone(),
            },
            ValueRecord::Bool { b, type_id } => ValueRecordWithType::Bool {
                b: *b,
                typ: self.db.types[*type_id].clone(),
            },
            ValueRecord::String { text, type_id } => ValueRecordWithType::String {
                text: text.to_string(),
                typ: self.db.types[*type_id].clone(),
            },
            ValueRecord::Sequence {
                elements,
                is_slice,
                type_id,
            } => ValueRecordWithType::Sequence {
                elements: elements.iter().map(|e| self.to_value_record_with_type(e)).collect(),
                is_slice: *is_slice,
                typ: self.db.types[*type_id].clone(),
            },
            ValueRecord::Tuple { elements, type_id } => ValueRecordWithType::Tuple {
                elements: elements.iter().map(|e| self.to_value_record_with_type(e)).collect(),
                typ: self.db.types[*type_id].clone(),
            },
            ValueRecord::Struct { field_values, type_id } => ValueRecordWithType::Struct {
                field_values: field_values.iter().map(|v| self.to_value_record_with_type(v)).collect(),
                typ: self.db.types[*type_id].clone(),
            },
            ValueRecord::Variant {
                discriminator,
                contents,
                type_id,
            } => ValueRecordWithType::Variant {
                discriminator: discriminator.clone(),
                contents: Box::new(self.to_value_record_with_type(&**contents)),
                typ: self.db.types[*type_id].clone(),
            },
            ValueRecord::Reference {
                dereferenced,
                address,
                mutable,
                type_id,
            } => ValueRecordWithType::Reference {
                dereferenced: Box::new(self.to_value_record_with_type(&**&dereferenced)),
                address: *address,
                mutable: *mutable,
                typ: self.db.types[*type_id].clone(),
            },
            ValueRecord::Raw { r, type_id } => ValueRecordWithType::Raw {
                r: r.clone(),
                typ: self.db.types[*type_id].clone(),
            },
            ValueRecord::Error { msg, type_id } => ValueRecordWithType::Error {
                msg: msg.clone(),
                typ: self.db.types[*type_id].clone(),
            },
            ValueRecord::None { type_id } => ValueRecordWithType::None {
                typ: self.db.types[*type_id].clone(),
            },
            ValueRecord::Cell { place } => ValueRecordWithType::Cell { place: place.clone() },
            ValueRecord::BigInt { b, negative, type_id } => ValueRecordWithType::BigInt {
                b: b.clone(),
                negative: *negative,
                typ: self.db.types[*type_id].clone(),
            },
        }
    }

    pub fn step_id_jump(&mut self, step_id: StepId) {
        if step_id.0 != NO_INDEX {
            self.step_id = step_id;
        }
    }

    fn to_program_event(&self, event_record: &DbRecordEvent, index: usize) -> ProgramEvent {
        let step_id_int = event_record.step_id.0;
        let (path, line) = if step_id_int != NO_INDEX {
            let step_record = &self.db.steps[event_record.step_id];
            (
                self.db
                    .workdir
                    .join(self.db.load_path_from_id(&step_record.path_id))
                    .display()
                    .to_string(),
                step_record.line.0,
            )
        } else {
            (NO_PATH.to_string(), NO_POSITION)
        };

        ProgramEvent {
            kind: event_record.kind,
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
            max_rr_ticks: self
                .db
                .steps
                .last()
                .unwrap_or(&DbStep {
                    step_id: StepId(0),
                    path_id: PathId(0),
                    line: Line(0),
                    call_key: CallKey(0),
                    global_call_key: CallKey(0),
                })
                .step_id
                .0,
        }
    }

    fn single_step_line(&self, step_index: usize, forward: bool) -> usize {
        // taking note of db.lines limits: returning a valid step id always
        if forward {
            if step_index < self.db.steps.len() - 1 {
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
        self.step_id = StepId(self.single_step_line(self.step_id.0 as usize, forward) as i64);
        Ok(true)
    }

    fn step_out(&mut self, forward: bool) -> Result<bool, Box<dyn Error>> {
        (self.step_id, _) = self.db.step_out_step_id_relative_to(self.step_id, forward);
        Ok(true)
    }

    fn next(&mut self, forward: bool) -> Result<bool, Box<dyn Error>> {
        let step_to_different_line = true; // which is better/should be let the user configure it?
        (self.step_id, _) = self
            .db
            .next_step_id_relative_to(self.step_id, forward, step_to_different_line);
        Ok(true)
    }

    // returns if it has hit any breakpoints
    fn step_continue(&mut self, forward: bool) -> Result<bool, Box<dyn Error>> {
        for step in self.db.step_from(self.step_id, forward) {
            if !self.breakpoint_list.is_empty() {
                if let Some(enabled) = self.breakpoint_list[step.path_id.0]
                    .get(&step.line.into())
                    .map(|bp| bp.enabled)
                {
                    if enabled {
                        self.step_id_jump(step.step_id);
                        // true: has hit a breakpoint
                        return Ok(true);
                    }
                }
            } else {
                break;
            }
        }

        // If the continue step doesn't find a valid breakpoint.
        if forward {
            self.step_id_jump(
                self.db
                    .steps
                    .last()
                    .expect("unexpected 0 steps in trace for step_continue")
                    .step_id,
            );
        } else {
            self.step_id_jump(
                self.db
                    .steps
                    .first()
                    .expect("unexpected 0 steps in trace for step_continue")
                    .step_id,
            )
        }
        // false: hasn't hit a breakpoint
        Ok(false)
    }

    fn load_path_id(&self, path: &str) -> Option<PathId> {
        self.db.path_map.get(path).copied()
    }

    fn id_to_name(&self, variable_id: VariableId) -> &String {
        &self.db.variable_names[variable_id]
    }
}

impl Replay for DbReplay {
    fn load_location(&mut self, expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
        info!("load_location: db replay");
        let call_key = self.db.call_key_for_step(self.step_id);
        self.call_key = call_key;
        let location = self.db.load_location(self.step_id, call_key, expr_loader);
        info!("  location: {location:?}");
        Ok(location)
    }

    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        self.step_id_jump(StepId(0));
        Ok(())
    }

    fn load_events(&mut self) -> Result<Events, Box<dyn Error>> {
        let mut events: Vec<ProgramEvent> = vec![];
        let mut first_events: Vec<ProgramEvent> = vec![];
        let mut contents: String = "".to_string();

        for (i, event_record) in self.db.events.iter().enumerate() {
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

    fn load_locals(&mut self, arg: CtLoadLocalsArguments) -> Result<Vec<VariableWithRecord>, Box<dyn Error>> {
        let variables_for_step = self.db.variables[self.step_id].clone();
        let full_value_locals: Vec<VariableWithRecord> = variables_for_step
            .iter()
            .map(|v| VariableWithRecord {
                expression: self.db.variable_name(v.variable_id).to_string(),
                value: self.to_value_record_with_type(&v.value),
                address: NO_ADDRESS,
                size: 0,
                // &self.db.to_ct_value(&v.value),
            })
            .collect();

        // TODO: fix random order here as well: ensure order(or in final locals?)
        let variable_cells_for_step = self.db.variable_cells[self.step_id].clone();
        let value_tracking_locals: Vec<VariableWithRecord> = variable_cells_for_step
            .iter()
            .map(|(variable_id, place)| {
                let name = self.db.variable_name(*variable_id);
                info!("log local {variable_id:?} {name} place: {place:?}");
                let value = self.db.load_value_for_place(*place, self.step_id);
                VariableWithRecord {
                    expression: self.db.variable_name(*variable_id).to_string(),
                    value: self.to_value_record_with_type(&value),
                    address: NO_ADDRESS,
                    size: 0,
                }
            })
            .collect();

        // TODO: watches require tracepoint-like evaluate_expression or would duplicate locals
        // for now don't evaluate/support them for db traces: just ignoring
        if arg.watch_expressions.len() > 0 {
            warn!("watch expressions not supported for db traces currently");
        }

        // based on https://stackoverflow.com/a/56490417/438099
        let mut locals: Vec<VariableWithRecord> = full_value_locals.into_iter().chain(value_tracking_locals).collect();

        locals.sort_by(|left, right| Ord::cmp(&left.expression, &right.expression));
        // for now just removing duplicated variables/expressions: even if storing different values
        locals.dedup_by(|a, b| a.expression == b.expression);

        Ok(locals)
    }

    fn load_memory_range(
        &mut self,
        arg: CtLoadMemoryRangeArguments,
    ) -> Result<CtLoadMemoryRangeResponseBody, Box<dyn Error>> {
        if arg.address < 0 {
            return Err("memory range address must be non-negative".into());
        }
        if arg.length < 0 {
            return Err("memory range length must be non-negative".into());
        }
        if arg.length > MAX_MEMORY_RANGE_BYTES {
            return Err(format!(
                "memory range length exceeds placeholder limit ({MAX_MEMORY_RANGE_BYTES} bytes)"
            )
            .into());
        }
        let length = arg.length as usize;
        // Placeholder until db replay supports actual memory reads.
        let bytes = vec![0u8; length];
        Ok(CtLoadMemoryRangeResponseBody {
            start_address: arg.address,
            length: arg.length,
            bytes_base64: STANDARD.encode(bytes),
            state: MemoryRangeState::Loaded,
            error: String::new(),
        })
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
        for variable in &self.db.variables[self.step_id] {
            if self.db.variable_names[variable.variable_id] == expression {
                return Ok(self.to_value_record_with_type(&variable.value.clone()));
            }
        }
        return Err(format!("variable {expression} not found on this step").into());
    }

    // currently depth_limit, lang only used for rr!
    // for db returning full values in their existing form
    fn load_return_value(
        &mut self,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        // assumes self.load_location() has been ran, and that we have the current call key
        Ok(self.to_value_record_with_type(&self.db.calls[self.call_key].return_value.clone()))
    }

    fn load_step_events(&mut self, step_id: StepId, exact: bool) -> Vec<DbRecordEvent> {
        self.db.load_step_events(step_id, exact)
    }

    fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn Error>> {
        warn!("load_callstack not implemented for db traces currently");
        Ok(vec![])
    }

    fn load_history(&mut self, arg: &LoadHistoryArg) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>> {
        let mut history_results: Vec<HistoryResultWithRecord> = vec![];
        // from start to end:
        //  find all steps with such a variable name: for them:
        //    detect if the value is the same as the previous value
        //    if not: add to the history

        self.jump_to(StepId(arg.location.rr_ticks.0))?;
        let current_call_key = self.db.steps[self.step_id].call_key;

        for (step_id, var_list) in self.db.variables.iter().enumerate() {
            let step = self.db.steps[StepId(step_id as i64)];
            // for now limit to current call: seems most correct
            // TODO: hopefully a more reliable value history for global search
            info!(
                "step call key {:?} current call key {:?}",
                step.call_key, current_call_key
            );
            if step.call_key == current_call_key {
                if let Some(var) = var_list
                    .iter()
                    .find(|v| *self.id_to_name(v.variable_id) == arg.expression)
                {
                    let step_location = Location::new(
                        &arg.location.path,
                        arg.location.line,
                        // assuming usize is always safely
                        // castable as i64 on 64bit arch?
                        RRTicks(step_id as i64),
                        &arg.location.function_name,
                        &arg.location.key,
                        &arg.location.global_call_key,
                        arg.location.callstack_depth,
                    );
                    // let ct_value = self.db.to_ct_value(&var.value);
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

    fn add_breakpoint(&mut self, path: &str, line: i64) -> Result<Breakpoint, Box<dyn Error>> {
        let path_id_res: Result<PathId, Box<dyn Error>> = self
            .load_path_id(path)
            .ok_or(format!("can't add a breakpoint: can't find path `{}`` in trace", path).into());
        let path_id = path_id_res?;
        let inner_map = &mut self.breakpoint_list[path_id.0];
        let breakpoint = Breakpoint {
            enabled: true,
            id: self.breakpoint_next_id as i64,
        };
        self.breakpoint_next_id += 1;
        inner_map.insert(line as usize, breakpoint.clone());
        Ok(breakpoint)
    }

    fn delete_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>> {
        for path_breakpoints in self.breakpoint_list.iter_mut() {
            if let Some(line) = path_breakpoints
                .iter()
                .find(|(_, stored)| stored.id == breakpoint.id)
                .map(|(line, _)| *line)
            {
                path_breakpoints.remove(&line);
                return Ok(true);
            }
        }

        Err(format!("breakpoint id {} not found", breakpoint.id).into())
    }

    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>> {
        self.breakpoint_list.clear();
        self.breakpoint_list.resize_with(self.db.paths.len(), HashMap::new);
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

    fn jump_to_call(&mut self, location: &Location) -> Result<Location, Box<dyn Error>> {
        let step = self.db.steps[StepId(location.rr_ticks.0)];
        let call_key = step.call_key;
        let first_call_step_id = self.db.calls[call_key].step_id;
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
}
