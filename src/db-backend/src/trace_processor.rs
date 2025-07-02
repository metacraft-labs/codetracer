use std::{collections::HashMap};
use std::error::Error;
use std::fs;
use std::path::Path;
use std::str;

use log::info;

// use log::info;
use runtime_tracing::{
    CallKey, EventLogKind, PathId, Place, StepId, TraceLowLevelEvent, TraceMetadata, TypeId, ValueRecord,
};

use crate::db::{CellChange, Db, DbCall, DbRecordEvent, DbStep, EndOfProgram};
// use crate::task::{Comp}

#[derive(Debug, Clone, Copy)]
struct CompoundValueInfo {
    item_count: usize,
    type_id: TypeId,
}

pub struct TraceProcessor<'a> {
    db: &'a mut Db,
    current_step_id: StepId,
    current_call_key: CallKey,
    last_started_call_key: CallKey,
    depth: usize,
    call_stack: Vec<CallKey>,
    last_compound_infos: HashMap<Place, CompoundValueInfo>,
}

impl<'a> TraceProcessor<'a> {
    pub fn new(db: &'a mut Db) -> Self {
        TraceProcessor {
            db,
            current_step_id: StepId(0),
            current_call_key: CallKey(-1),
            last_started_call_key: CallKey(-1),
            depth: 0,
            call_stack: vec![],
            last_compound_infos: HashMap::new(),
        }
    }

    pub fn postprocess(&mut self, events: &[TraceLowLevelEvent]) -> Result<(), Box<dyn Error>> {
        // can be huge: only for small traces
        // info!("backend: low level trace: {:#?}", trace);

        // let step_map = index_step_map(&trace.steps);
        // let path_map = index_path_map(&trace.paths); // return hashmap
        // let paths = index_paths(&trace.paths);

        for event in events {
            info!("!!!!Processing event: {:?}", event);
            self.process_event(event)?;
            if let Some(x) = self.db.steps.get(StepId(8)) {
                info!("LINE 74 CALL KEY: {:?}", x);
            }
        }

        while self.db.variables.len() > self.db.steps.len() {
            self.db.variables.pop();
        }
        assert!(
            self.db.variables.len() == self.db.steps.len(),
            "db.variables has different length than db.steps, can't ensure StepId remains valid index for it"
        );
        assert!(
            self.db.instructions.len() == self.db.steps.len(),
            "db.instructions has different length than db.steps, can't ensure StepId remains valid index for it",
        );

        self.db.end_of_program = if !self.db.events.is_empty() {
            let last_event = &self.db.events[self.db.events.len() - 1];
            let on_last_step = (last_event.step_id.0 as usize) == self.db.steps.len() - 1;
            if last_event.kind == EventLogKind::Error && on_last_step {
                let reason = format!("error: {}", last_event.content);
                EndOfProgram::Error { reason }
            } else {
                EndOfProgram::Normal
            }
        } else {
            EndOfProgram::Normal
        };

        Ok(())
    }

    #[allow(clippy::expect_used)]
    fn process_event(&mut self, event: &TraceLowLevelEvent) -> Result<(), Box<dyn Error>> {
        // info!("process_event {:?}", event);
        match event {
            TraceLowLevelEvent::Step(step_record) => {
                assert!(self.current_call_key.0 >= 0);
                let db_step = DbStep {
                    step_id: StepId(self.db.steps.len() as i64),
                    path_id: step_record.path_id,
                    line: step_record.line,
                    call_key: self.current_call_key,
                    global_call_key: self.last_started_call_key,
                };

                // info!("step with #{} and call key {:?}", db_step.step_id.0, db_step.call_key);

                info!("Processed step with line: {:?} for call key {:?}", step_record.line, db_step.call_key);

                self.db.steps.push(db_step);
                self.db.variables.push(vec![]);
                self.db.instructions.push(vec![]);
                self.db.compound.push(HashMap::new());
                // self.db.compound_items.push(HashMap::new());
                self.db.cells.push(HashMap::new());
                self.db.variable_cells.push(HashMap::new());
                // TODO
                self.db.local_variable_cells.push(HashMap::new());

                let step_variable_cells = &mut self.db.variable_cells[self.current_step_id];

                if self.depth > 0 {
                    let current_call_variable_cells = &self.db.local_variable_cells[self.depth - 1];
                    for (variable_id, place) in current_call_variable_cells.iter() {
                        // info!("trace for step: {variable_id:?} {place:?}");
                        step_variable_cells.insert(*variable_id, *place);
                    }
                }

                if step_record.line.0 >= 0 {
                    let line_number_usize = step_record.line.0 as usize;
                    let step_map_length = self.db.step_map.len();
                    if step_map_length < step_record.path_id.0 + 1 {
                        for _ in step_map_length..step_record.path_id.0 + 1 {
                            self.db.step_map.push(HashMap::new());
                        }
                    }

                    // copied and adapted from
                    // https://stackoverflow.com/a/67376360/438099

                    let lines_for_path = &mut self.db.step_map[step_record.path_id];

                    lines_for_path.entry(line_number_usize).or_default();
                    let lines_for_path_and_line = lines_for_path
                        .get_mut(&line_number_usize)
                        .expect("expect existing hashmap for line");

                    lines_for_path_and_line.push(db_step);
                }
                self.current_step_id = StepId(self.db.steps.len() as i64 - 1);
                info!("Current step id: {:?}", self.current_step_id);
            }
            TraceLowLevelEvent::Path(path) => {
                let path_string = path.display().to_string();
                self.db.paths.push(path_string.clone());
                self.db.path_map.insert(path_string, PathId(self.db.paths.len() - 1));
            }
            TraceLowLevelEvent::VariableName(name) => {
                self.db.variable_names.push(name.to_string());
            }
            TraceLowLevelEvent::Variable(name) => {
                self.db.variable_names.push(name.to_string());
            }
            TraceLowLevelEvent::Type(type_record) => self.db.types.push(type_record.clone()),
            TraceLowLevelEvent::Value(full_value_record) => {
                // We need this loop if any of the variables are registered before the first step
                // Using while for safe measures instead of a condition statement
                while (self.db.variables.len() as i64) < self.current_step_id.0 + 1 {
                    self.db.variables.push(vec![]);
                }
                self.db.variables[self.current_step_id].push(full_value_record.clone())
            }
            TraceLowLevelEvent::Function(function_record) => {
                // info!("function {:?}", function_record);
                self.db.functions.push(function_record.clone());
            }
            TraceLowLevelEvent::Call(call_record) => {
                let parent_key = if !self.call_stack.is_empty() {
                    // len() > 0 {
                    self.call_stack[self.call_stack.len() - 1]
                } else {
                    CallKey(-1)
                };

                info!("WE HAVE A NEW CALL: {:?}", self.db.functions[call_record.function_id]);

                self.current_call_key = CallKey(self.db.calls.len() as i64);
                self.last_started_call_key = self.current_call_key;

                // info!(
                //     "call {:?} with function id {:?}",
                //     self.current_call_key, call_record.function_id
                // );
                self.db.calls.push(DbCall {
                    key: self.current_call_key,
                    function_id: call_record.function_id,
                    args: call_record.args.clone(),
                    return_value: ValueRecord::None { type_id: TypeId(0) },
                    step_id: self.current_step_id,
                    depth: self.depth,
                    parent_key,
                    children_keys: vec![],
                });
                if self.db.variables.is_empty() {
                    self.db.variables.push(vec![]);
                }

                for arg in call_record.args.iter() {
                    self.db.variables[self.current_step_id].push(arg.clone())
                }

                let current_step_id_usize = self.current_step_id.0 as usize;
                if current_step_id_usize > 0 && current_step_id_usize < self.db.steps.len() {

                    // not true for 0 sometimes: no step for first top-level call:
                    self.db.steps[self.current_step_id].call_key = self.current_call_key;
                    self.db.steps[self.current_step_id].global_call_key = self.current_call_key;
                }

                // self.db.call_children_id_map.push(vec![]);
                assert!(self.db.calls.len() == self.current_call_key.0 as usize + 1);

                if parent_key.0 >= 0 {
                    self.db.calls[parent_key].children_keys.push(self.current_call_key);
                }
                self.call_stack.push(self.current_call_key);
                self.db.local_variable_cells.push(HashMap::new());
                self.depth += 1;
                // make sure it's cleared, if we've added a new one on a deeper level
                self.db.local_variable_cells[self.depth - 1].clear();
            }
            TraceLowLevelEvent::Return(return_record) => {
                // we must have a top-level call which means
                // we should have no return for it!
                // we should have always at least it there: at least 1
                // assert!(self.depth > 1);
                // assert!(self.call_stack.len() > 1);
                assert!(self.depth > 0);
                self.depth -= 1;
                self.db.calls[self.current_call_key].return_value = return_record.return_value.clone();
                let _ = self.call_stack.pop();
                let _ = self.db.local_variable_cells.pop();
                if !self.call_stack.is_empty() {
                    self.current_call_key = self.call_stack[self.call_stack.len() - 1];
                }
            }
            TraceLowLevelEvent::Event(record_event) => {
                self.db.events.push(DbRecordEvent {
                    kind: record_event.kind,
                    content: record_event.content.clone(),
                    step_id: self.current_step_id,
                });
            }
            TraceLowLevelEvent::DropLastStep => {
                assert!(self.current_step_id.0 > 0);
                assert!(!self.db.steps.is_empty());
                assert!(!self.db.variables.is_empty());

                let last_step = self.db.steps.pop().expect("at least one step");
                let _ = self.db.variables.pop().expect("at least one step variables section");
                let _ = self.db.compound.pop().expect("at least one compound hashmap");
                // let _ = self
                //     .db
                //     .compound_items
                //     .pop()
                //     .expect("at least one compound_items section");
                let _ = self.db.cells.pop().expect("at least one cells section");

                if last_step.line.0 >= 0 {
                    let line_number_usize = last_step.line.0 as usize;
                    // copied and adapted from ::Step handling
                    // with hash handling which is
                    // copied and adapted from
                    // https://stackoverflow.com/a/67376360/438099
                    let step_map_length = self.db.step_map.len();
                    if step_map_length < last_step.path_id.0 + 1 {
                        for _ in step_map_length..last_step.path_id.0 + 1 {
                            self.db.step_map.push(HashMap::new());
                        }
                    }
                    let lines_for_path = &mut self.db.step_map[last_step.path_id];

                    lines_for_path.entry(line_number_usize).or_default();
                    let lines_for_path_and_line = lines_for_path
                        .get_mut(&line_number_usize)
                        .expect("expect existing hashmap for line");

                    let _ = lines_for_path_and_line.pop();
                }

                // => steps is decreasing, so step id is also decreasing with 1
                self.current_step_id = StepId(self.db.steps.len() as i64 - 1);
            }

            TraceLowLevelEvent::BindVariable(_record) => {
                unimplemented!() // experimental, not ready
            }
            TraceLowLevelEvent::Assignment(_record) => {
                unimplemented!() // experimental, not ready
            }
            TraceLowLevelEvent::DropVariables(_record) => {
                unimplemented!() // experimental, not ready
            }

            TraceLowLevelEvent::CompoundValue(record) => {
                self.db.compound[self.current_step_id].insert(record.place, record.value.clone());
                if let ValueRecord::Sequence {
                    elements,
                    type_id,
                    is_slice: _,
                } = &record.value
                {
                    // for now is_slice not supported, but this is an experimental API: TODO rework it
                    let compound_info = CompoundValueInfo {
                        item_count: elements.len(),
                        type_id: *type_id,
                    };
                    self.last_compound_infos.insert(record.place, compound_info);
                    self.register_cell_change(
                        record.place,
                        compound_info.item_count,
                        Some(compound_info.type_id),
                        None,
                        None,
                    );
                    #[allow(clippy::needless_range_loop)]
                    for i in 0..compound_info.item_count {
                        if let ValueRecord::Cell { place: item_place } = &elements[i] {
                            self.register_compound_cell_change(
                                record.place,
                                compound_info.item_count,
                                compound_info.type_id,
                                i,
                                *item_place,
                            );
                        }
                    }
                } else {
                    todo!();
                };
            }
            TraceLowLevelEvent::CellValue(record) => {
                self.db.cells[self.current_step_id].insert(record.place, record.value.clone());
                self.register_simple_cell_change(record.place);
            }
            TraceLowLevelEvent::AssignCompoundItem(record) => {
                let last_compound_info = self
                    .last_compound_infos
                    .get(&record.place)
                    .expect("at least one register of compound value before assigning its item");
                self.register_compound_cell_change(
                    record.place,
                    last_compound_info.item_count,
                    last_compound_info.type_id,
                    record.index,
                    record.item_place,
                );
            }
            TraceLowLevelEvent::AssignCell(record) => {
                self.db.cells[self.current_step_id].insert(record.place, record.new_value.clone());
                self.register_simple_cell_change(record.place);
            }
            TraceLowLevelEvent::VariableCell(record) => {
                // self.depth should be >= 1 always,
                // as a top-level-code `Call` event should be before all steps
                // and that call should continue to end, still a bit worrying maybe
                let current_call_variable_cells = &mut self.db.local_variable_cells[self.depth - 1];
                current_call_variable_cells.insert(record.variable_id, record.place);

                let step_variable_cells = &mut self.db.variable_cells[self.current_step_id];
                step_variable_cells.insert(record.variable_id, record.place);

                // let name = self.db.variable_name(record.variable_id);
                // info!(
                //     "register current call variable {:?}({}) {:?}",
                //     record.variable_id, name, record.place
                // );
            }
            TraceLowLevelEvent::DropVariable(variable_id) => {
                // self.depth should be >= 1 always,
                // as a top-level-code `Call` event should be before all steps
                // and that call should continue to end, still a bit worrying maybe
                let current_call_variable_cells = &mut self.db.local_variable_cells[self.depth - 1];
                let _ = current_call_variable_cells.remove(variable_id);

                // let name = self.db.variable_name(*variable_id);
                // info!("drop current call variable {:?}({})", *variable_id, name);
            }
            TraceLowLevelEvent::Asm(asm_record) => {
                self.db.instructions[self.current_step_id].extend(asm_record.clone());
            }
        }
        Ok(())
    }

    fn register_simple_cell_change(&mut self, place: Place) {
        self.register_cell_change(place, 0, None, None, None);
    }

    fn register_compound_cell_change(
        &mut self,
        place: Place,
        item_count: usize,
        type_id: TypeId,
        index: usize,
        item_place: Place,
    ) {
        self.register_cell_change(place, item_count, Some(type_id), Some(index), Some(item_place));
    }

    fn register_cell_change(
        &mut self,
        place: Place,
        item_count: usize,
        type_id: Option<TypeId>,
        index: Option<usize>,
        item_place: Option<Place>,
    ) {
        let value_cell_changes = &mut self.db.cell_changes.entry(place).or_default();
        value_cell_changes.push(CellChange {
            step_id: self.current_step_id,
            item_count,
            type_id,
            index,
            item_place,
        });
    }
}

#[allow(clippy::panic)]
pub fn load_trace_data(trace_file: &Path, file_format: runtime_tracing::TraceEventsFileFormat) -> Result<Vec<TraceLowLevelEvent>, Box<dyn Error>> {
    let mut tracer = runtime_tracing::Tracer::new("", &[]);
    tracer.load_trace_events(trace_file, file_format)?;

    Ok(tracer.events)
}

#[allow(clippy::panic)]
pub fn load_trace_metadata(trace_metadata_file: &Path) -> Result<TraceMetadata, Box<dyn Error>> {
    let raw_bytes =
        fs::read(trace_metadata_file).unwrap_or_else(|_| panic!("metadata file {trace_metadata_file:?} read error"));
    let raw = str::from_utf8(&raw_bytes)?;

    let trace_metadata: TraceMetadata = serde_json::from_str(raw)?;

    Ok(trace_metadata)
}
