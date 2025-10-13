use num_bigint::BigInt;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::vec::Vec;

use crate::distinct_vec::DistinctVec;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
use crate::task::{Call, CallArg, Location, RRTicks};
use crate::value::{Type, Value};
use log::{error, info, warn};
use runtime_tracing::{
    CallKey, EventLogKind, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, Place, StepId, TypeId, TypeKind,
    TypeRecord, TypeSpecificInfo, ValueRecord, VariableId, NO_KEY,
};

const NEXT_INTERNAL_STEP_OVERS_LIMIT: usize = 1_000;

#[derive(Debug)]
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

    pub fn step_from(&self, step_id: StepId, forward: bool) -> StepIterator {
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
                    let function_record = &self.functions[self.calls[CallKey(call_key_int)].function_id];
                    let lang = expr_loader.get_current_language(&PathBuf::from(path));
                    let fn_line: Line = if lang == Lang::Noir {
                        Line(function_record.line.0 - 1)
                    } else {
                        function_record.line
                    };
                    let (fn_start, fn_last) = expr_loader.get_first_last_fn_lines(&location, &fn_line);
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
                discriminator: _,
                contents: _,
                type_id: _,
            } => {
                // variant-like enums not generated yet from noir tracer:
                //   we should support variants in general, but we'll think a bit first how
                //   to more cleanly/generally represent them in the codetracer code, as the current
                //   `Value` mapping doesn't seem great imo
                //   we can improve it, or we can add a new variant case (something more similar to the runtime_tracing repr?)
                todo!("a more suitable codetracer value/type for variants")
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
                compound_value.clone() // register or assign?
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
