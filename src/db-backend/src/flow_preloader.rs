use crate::{
    db::{Db, DbRecordEvent, DbStep},
    expr_loader::ExprLoader,
    task::{
        BranchesTaken, CoreTrace, FlowEvent, FlowStep, FlowUpdate, FlowUpdateState, FlowUpdateStateKind,
        FlowViewUpdate, Iteration, Location, Loop, LoopId, LoopIterationSteps, Position, RRTicks, StepCount,
    },
};
use log::{info, warn};
use runtime_tracing::{CallKey, FullValueRecord, Line, StepId};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

#[derive(Debug)]
pub struct FlowPreloader {
    pub expr_loader: ExprLoader,
}

#[allow(clippy::new_without_default)]
impl FlowPreloader {
    pub fn new() -> Self {
        FlowPreloader {
            expr_loader: ExprLoader::new(CoreTrace::default()),
        }
    }

    pub fn load(&mut self, location: Location, line: Line, mode: FlowMode, db: &Db) -> FlowUpdate {
        info!("flow: load: {:?}", location);
        let path_buf = PathBuf::from(&location.path);
        match self.expr_loader.load_file(&path_buf) {
            Ok(_) => {
                info!("Expression loader complete!");
                let mut call_flow_preloader: CallFlowPreloader = CallFlowPreloader::new(self, location, HashSet::new(), HashSet::new(), mode);
                call_flow_preloader.load_flow(line, db)
            }
            Err(e) => {
                warn!("can't process file {}: error {}", location.path, e);
                FlowUpdate::error(&format!("can't process file {}", location.path))
            }
        }
    }

    pub fn load_diff_flow(&mut self, diff_lines: HashSet<(PathBuf, i64)>, db: &Db) -> FlowUpdate {
        for diff_line in &diff_lines {
            match self.expr_loader.load_file(&diff_line.0) {
                Ok(_) => {
                    continue;
                }
                Err(e) => {
                    warn!("can't process file {}: error {}", diff_line.0.display(), e);
                    return FlowUpdate::error(&format!("can't process file {}", diff_line.0.display()));
                }
            }
        }

        let mut diff_call_keys = HashSet::new();
        for step in db.step_from(runtime_tracing::StepId(0), true) {
            if diff_lines.contains(&(PathBuf::from(db.paths[step.path_id].clone()), step.line.0)) {
                diff_call_keys.insert(step.call_key.0);
            }
        }
       
        let mut call_flow_preloader = CallFlowPreloader::new(self, Location::default(), diff_lines, diff_call_keys, FlowMode::Diff);
        call_flow_preloader.load_flow(Line(1), db)
    }

    // fn load_file(&mut self, path: &str) {
    // self.expr_loader.load_file(&PathBuf::from(path.to_string())).unwrap();
    // }

    pub fn get_var_list(&self, line: Line, location: &Location) -> Option<Vec<String>> {
        self.expr_loader.get_expr_list(line, location)
    }

    // fn get_function_location(&self, location: &Location, line: &Line) -> Location {
    // self.expr_loader.find_function_location(location, line)
    // }
}

#[repr(C)]
#[derive(Debug, Clone, PartialEq)]
pub enum FlowMode {
    Call,
    Diff,
}

pub struct CallFlowPreloader<'a> {
    flow_preloader: &'a FlowPreloader,
    location: Location,
    active_loops: Vec<Position>,
    last_step_id: StepId,
    last_expr_order: Vec<String>,
    diff_lines: HashSet<(PathBuf, i64)>,
    diff_call_keys: HashSet<i64>, //  TODO: if we add Eq, Hash it seems we can do CallKey
    mode: FlowMode,
}

impl<'a> CallFlowPreloader<'a> {
    pub fn new(flow_preloader: &'a FlowPreloader, location: Location, diff_lines: HashSet<(PathBuf, i64)>, diff_call_keys: HashSet<i64>, mode: FlowMode) -> Self {
        CallFlowPreloader {
            flow_preloader,
            location,
            active_loops: vec![],
            last_step_id: StepId(-1),
            last_expr_order: vec![],
            diff_lines,
            diff_call_keys,
            mode,
        }
    }

    // TODO:
    // refactor load_flow to several methods

    // TODO:
    //   we can add a NonEmptyVec or VecWithSizeAtLeast<1, ..>
    //   and with limiting its API we can make sure
    //   a `[0]` or `last()` method is safe, and remove unwraps
    //
    //   for now manually we saw that most collections which we
    //   use last/last_mut on seem to have at least 1 element
    //   by construction or because we push to them before using
    //   last
    //
    #[allow(clippy::unwrap_used)]
    pub fn load_flow(&mut self, line: Line, db: &Db) -> FlowUpdate {
        // Update location on flow load
        if self.mode == FlowMode::Call {
            self.location = self
                .flow_preloader
                .expr_loader
                .find_function_location(&self.location, &line);
        }

        // info!("location flow {:?}", self.location);

        let mut flow_update = FlowUpdate::new();
        let flow_view_update = self.load_view_update(db);

        flow_update.location = self.location.clone();
        flow_update.view_updates.push(flow_view_update);
        flow_update.status = FlowUpdateState {
            kind: FlowUpdateStateKind::FlowFinished,
            steps: 0,
        };
        flow_update
    }

    fn add_return_value(&mut self, mut flow_view_update: FlowViewUpdate, db: &Db, call_key: CallKey) -> FlowViewUpdate {
        // The if condition ensures, that the Options on which .unwrap() is called
        // are never None, so it is safe to unwrap them.
        let return_string = "return".to_string();
        if !flow_view_update.steps.is_empty() {
            #[allow(clippy::unwrap_used)]
            flow_view_update.steps.last_mut().unwrap().before_values.insert(
                return_string.clone(),
                db.to_ct_value(&db.calls[call_key].return_value.clone()),
            );

            #[allow(clippy::unwrap_used)]
            flow_view_update
                .steps
                .last_mut()
                .unwrap()
                .expr_order
                .push(return_string.clone());

            #[allow(clippy::unwrap_used)]
            flow_view_update.steps.first_mut().unwrap().before_values.insert(
                return_string.clone(),
                db.to_ct_value(&db.calls[call_key].return_value.clone()),
            );

            #[allow(clippy::unwrap_used)]
            flow_view_update
                .steps
                .first_mut()
                .unwrap()
                .expr_order
                .push(return_string);
        }
        flow_view_update
    }

    fn next_diff_flow_step(&self, from_step_id: StepId, including_from: bool, db: &Db) -> (StepId, bool) {
        if from_step_id.0 >= db.steps.len() as i64 {
            (from_step_id, false)
        } else {
            // TODO: next diff step
            let mut next_step_id = if !including_from { from_step_id + 1 } else { from_step_id };
            loop {
                if next_step_id.0 >= db.steps.len() as i64 { // must be + 1! then we assume we should stay and report not progressing
                    return (from_step_id, false);
                }
                let next_step = db.steps[next_step_id];
                info!("check {:?}", (PathBuf::from(db.paths[next_step.path_id].clone()), next_step.line.0));
                if self.diff_call_keys.contains(&next_step.call_key.0) {
                    // &(PathBuf::from(db.paths[next_step.path_id].clone()), next_step.line.0)) {
                    return (next_step_id, true);
                } else {
                    next_step_id = next_step_id + 1;
                    continue;
                }
            }
        }
    }

    fn find_first_step(&self, from_step_id: StepId, db: &Db) -> (StepId, bool) {
        match self.mode {
            FlowMode::Call => (from_step_id, true),
            FlowMode::Diff => self.next_diff_flow_step(StepId(0), true, db),
        }
    }

    fn find_next_step(&self, from_step_id: StepId, db: &Db) -> (StepId, bool) {
        let step_to_different_line = true; // for flow for now makes sense to try to always reach a new line
        match self.mode {
            FlowMode::Call => db.next_step_id_relative_to(from_step_id, true, step_to_different_line),
            FlowMode::Diff => self.next_diff_flow_step(from_step_id, false, db),
        }
    }

    fn load_view_update(&mut self, db: &Db) -> FlowViewUpdate {
        let start_step_id = StepId(self.location.rr_ticks.0);
        let call_key: CallKey = db.steps[start_step_id].call_key;
        // let mut path_buf = &PathBuf::from(&self.location.path);
        let mut iter_step_id = db.calls[call_key].step_id;
        let mut flow_view_update = FlowViewUpdate::new(self.location.clone());
        let mut step_count = 0;
        let mut first = true;
        info!("loop");
        loop {
            let (step_id, progressing) = if first {
                first = false;
                self.find_first_step(iter_step_id, db)
            } else {
                self.find_next_step(iter_step_id, db)
            };
            iter_step_id = step_id;
            let step = db.steps[step_id];
            if self.mode == FlowMode::Diff {
                let mut expr_loader = ExprLoader::new(CoreTrace::default());
                self.location = db.load_location(step_id, step.call_key, &mut expr_loader);
            }
            if self.mode == FlowMode::Call && call_key != step.call_key || !progressing {
                flow_view_update = self.add_return_value(flow_view_update, db, call_key);
                info!("break flow");
                break;
            }

            let events = self.load_step_flow_events(db, step_id);
            // for now not sending last step id for line visit
            // but this flow step object *can* contain info about several actual steps
            // e.g. events from some of the next steps on the same line visit
            // one can analyze the step id of the next step, or we can add this info to the object
            flow_view_update.steps.push(FlowStep::new(
                step.line.0,
                step_count,
                step.step_id,
                Iteration(0),
                LoopId(0),
                events,
            ));
            flow_view_update.relevant_step_count.push(step.line.0 as usize);
            flow_view_update.add_step_count(step.line.0, step_count);
            info!("process loops");
            let path_buf = &PathBuf::from(&self.location.path);
            flow_view_update = self.process_loops(flow_view_update.clone(), step, path_buf, step_count);
            flow_view_update = self.log_expressions(flow_view_update.clone(), step, db, step_id);
            step_count += 1;
        }
        let path_buf = &PathBuf::from(&self.location.path);
        // TODO: maybe not true for diff flow, we can have multiple files/paths there 
        flow_view_update.comment_lines = self.flow_preloader.expr_loader.get_comment_positions(path_buf);
        flow_view_update.add_branches(
            0,
            self.flow_preloader
                .expr_loader
                .final_branch_load(path_buf, &flow_view_update.branches_taken[0][0].table),
        );
        flow_view_update
    }

    #[allow(clippy::unwrap_used)]
    fn process_loops(
        &mut self,
        mut flow_view_update: FlowViewUpdate,
        step: DbStep,
        path_buf: &PathBuf,
        step_count: i64,
    ) -> FlowViewUpdate {
        if let Some(loop_shape) = self.flow_preloader.expr_loader.get_loop_shape(&step, path_buf) {
            if loop_shape.first.0 == step.line.0 && !self.active_loops.contains(&loop_shape.first) {
                flow_view_update.loops.push(Loop {
                    base: LoopId(loop_shape.loop_id.0),
                    base_iteration: Iteration(0),
                    internal: vec![],
                    first: loop_shape.first,
                    last: loop_shape.last,
                    registered_line: loop_shape.first,
                    iteration: Iteration(0),
                    step_counts: vec![StepCount(step_count)],
                    rr_ticks_for_iterations: vec![RRTicks(step.step_id.0)],
                });
                self.active_loops.push(loop_shape.first);
                flow_view_update
                    .loop_iteration_steps
                    .push(vec![LoopIterationSteps::default()]);
                flow_view_update.branches_taken.push(vec![BranchesTaken::default()]);
            } else if (flow_view_update.loops.last().unwrap().first.0) == step.line.0 {
                flow_view_update.loops.last_mut().unwrap().iteration.inc();
                flow_view_update
                    .loop_iteration_steps
                    .last_mut()
                    .unwrap()
                    .push(LoopIterationSteps::default());
                flow_view_update
                    .branches_taken
                    .last_mut()
                    .unwrap()
                    .push(BranchesTaken::default());
                flow_view_update
                    .loops
                    .last_mut()
                    .unwrap()
                    .rr_ticks_for_iterations
                    .push(RRTicks(step.step_id.0));
            }
        }

        if flow_view_update.loops.last().unwrap().first.0 <= step.line.0
            && flow_view_update.loops.last().unwrap().last.0 >= step.line.0
        {
            flow_view_update.steps.last_mut().unwrap().iteration =
                Iteration(flow_view_update.loops.last().unwrap().iteration.0);
            flow_view_update.steps.last_mut().unwrap().r#loop = flow_view_update.loops.last().unwrap().base.clone();
            let index = (flow_view_update.loops.last().unwrap().base.0) as usize;
            if index < flow_view_update.loop_iteration_steps.len() {
                flow_view_update
                    .loops
                    .last_mut()
                    .unwrap()
                    .step_counts
                    .push(StepCount(step_count));
                flow_view_update.loop_iteration_steps[index]
                    .last_mut()
                    .unwrap()
                    .table
                    .insert(step.line.0 as usize, step_count as usize);
                flow_view_update.add_branches(
                    flow_view_update.loops.clone().last_mut().unwrap().base.0,
                    self.flow_preloader.expr_loader.load_branch_for_step(&step, path_buf),
                );
            }
        } else {
            flow_view_update.loop_iteration_steps[0][0]
                .table
                .insert(step.line.0 as usize, step_count as usize);
            flow_view_update.add_branches(0, self.flow_preloader.expr_loader.load_branch_for_step(&step, path_buf));
        }
        flow_view_update
    }

    fn to_flow_event(&self, event: &DbRecordEvent) -> FlowEvent {
        FlowEvent {
            kind: event.kind,
            text: event.content.clone(),
            rr_ticks: event.step_id.0,
            metadata: event.metadata.clone(),
        }
    }

    fn load_step_flow_events(&self, db: &Db, step_id: StepId) -> Vec<FlowEvent> {
        // load not only exactly this step, but for the whole step line "visit":
        // include events for next steps for this visit, because we don't process those steps in flow
        // otherwise, but we do something like a `next`
        let exact = false;
        let step_events = db.load_step_events(step_id, exact);
        let flow_events = step_events.iter().map(|event| self.to_flow_event(event)).collect();
        // info!("flow events: {flow_events:?}");
        #[allow(clippy::let_and_return)] // useful to have the variable for debugging/logging
        flow_events
    }

    #[allow(clippy::unwrap_used)]
    fn log_expressions(
        &mut self,
        mut flow_view_update: FlowViewUpdate,
        step: DbStep,
        db: &Db,
        step_id: StepId,
    ) -> FlowViewUpdate {
        let mut expr_order: Vec<String> = vec![];
        let mut variable_map: HashMap<String, FullValueRecord> = HashMap::default();

        for value_record in &db.variables[step_id] {
            variable_map.insert(
                db.variable_names[value_record.variable_id].clone(),
                value_record.clone(),
            );
        }

        for (variable_id, place) in &db.variable_cells[step_id] {
            let value_record = db.load_value_for_place(*place, step_id);
            let full_value_record = FullValueRecord {
                variable_id: *variable_id,
                value: value_record,
            };
            let name = db.variable_name(*variable_id);
            variable_map.insert(name.clone(), full_value_record);
        }

        if let Some(var_list) = self.flow_preloader.get_var_list(step.line, &self.location) {
            info!("var_list {:?}", var_list.clone());
            for value_name in &var_list {
                if variable_map.contains_key(value_name) {
                    flow_view_update
                        .steps
                        .last_mut()
                        .unwrap()
                        .before_values
                        .insert(value_name.clone(), db.to_ct_value(&variable_map[value_name].value));
                }
                expr_order.push(value_name.clone());
            }

            flow_view_update.steps.last_mut().unwrap().expr_order = expr_order.clone();
        }

        if self.last_step_id.0 >= 0 && flow_view_update.steps.len() >= 2 {
            let index = flow_view_update.steps.len() - 2;

            for variable in &self.last_expr_order {
                if variable_map.contains_key(variable) {
                    flow_view_update.steps[index]
                        .after_values
                        .insert(variable.clone(), db.to_ct_value(&variable_map[variable].value));
                }
            }
        }

        self.last_step_id = step_id;
        self.last_expr_order = expr_order;
        flow_view_update
    }
}
