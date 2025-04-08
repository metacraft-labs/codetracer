use indexmap::IndexMap;
use std::collections::HashMap;
use std::error::Error;
use std::sync::mpsc;

use log::{error, info, warn};
use regex::Regex;
use serde::{Deserialize, Serialize};

use runtime_tracing::{CallKey, EventLogKind, Line, PathId, StepId, VariableId, NO_KEY};

use crate::calltrace::Calltrace;
use crate::db::{Db, DbCall, DbRecordEvent, DbStep};
use crate::event_db::{EventDb, SingleTableId};
use crate::expr_loader::ExprLoader;
use crate::flow_preloader::FlowPreloader;
use crate::program_search_tool::ProgramSearchTool;
use crate::response::{Event, Response, TaskResult, VOID_RESULT};
use crate::sender;
use crate::step_lines_loader::StepLinesLoader;
use crate::task::{
    gen_event_id, gen_task_id, Action, Call, CallArgsUpdateResults, CallLine, CallSearchArg, CalltraceLoadArgs,
    CalltraceNonExpandedKind, CollapseCallsArgs, ConfigureArg, CoreTrace, DbEventKind, EventKind, FrameInfo,
    FunctionLocation, HistoryResult, HistoryUpdate, Instruction, Instructions, LoadHistoryArg, LoadStepLinesArg,
    LoadStepLinesUpdate, LocalStepJump, Location, MoveState, Notification, NotificationKind, ProgramEvent,
    RRGDBStopSignal, RRTicks, RegisterEventsArg, RunTracepointsArg, SourceCallJumpTarget, SourceLocation, StepArg,
    Stop, StopType, Task, TaskKind, TraceUpdate, TracepointId, TracepointResults, UpdateTableArgs, Variable, NO_INDEX,
    NO_PATH, NO_POSITION, NO_STEP_ID,
};
use crate::tracepoint_interpreter::TracepointInterpreter;

const TRACEPOINT_RESULTS_LIMIT_BEFORE_UPDATE: usize = 5;

#[derive(Debug)]
pub struct Handler {
    pub db: Box<Db>,
    pub step_id: StepId,
    pub last_call_key: CallKey,
    pub sender_tx: mpsc::Sender<Response>,
    pub indirect_send: bool,
    pub sender: sender::Sender,
    pub event_db: EventDb,
    pub flow_preloader: FlowPreloader,
    pub expr_loader: ExprLoader,
    pub calltrace: Calltrace,
    pub step_lines_loader: StepLinesLoader,
    pub trace: CoreTrace,

    pub breakpoint_list: Vec<HashMap<usize, BreakpointRecord>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BreakpointRecord {
    pub is_active: bool,
}

type LineTraceMap = HashMap<usize, Vec<(usize, String)>>;

// two choices:
//   return results and potentially
//   generate multiple events as a generator
//
// or just use Sender and directly
//   call its methods when needed
//
// e.g.
//
//
// ->
// 1 variant:
//   return type -> Message
//
// 2 variant:
//   receives sender as arg
//   sender.

impl Handler {
    pub fn new(db: Box<Db>, sender_tx: mpsc::Sender<Response>) -> Handler {
        Self::construct(db, sender_tx, false)
    }

    pub fn construct(db: Box<Db>, sender_tx: mpsc::Sender<Response>, indirect_send: bool) -> Handler {
        let calltrace = Calltrace::new(&db);
        let trace = CoreTrace::default();
        let mut expr_loader = ExprLoader::new(trace.clone());
        let mut breakpoint_list: Vec<HashMap<usize, BreakpointRecord>> = Default::default();
        breakpoint_list.resize_with(db.paths.len(), HashMap::new);
        let step_lines_loader = StepLinesLoader::new(&db, &mut expr_loader);
        let sender = sender::Sender::new();
        Handler {
            db,
            step_id: StepId(0),
            last_call_key: CallKey(0),
            sender_tx,
            indirect_send,
            sender,
            breakpoint_list,
            event_db: EventDb::new(),
            flow_preloader: FlowPreloader::new(),
            expr_loader,
            trace,
            calltrace,
            step_lines_loader,
        }
    }
    // TODO

    // load-calltrace parameters
    // <- calltrace-update 1
    // <- ..

    // normal workflow
    //
    // -> from local db/trace: trace source folders
    // start-0
    // run-to-entry-0 -> CompleteMove event
    //   load-locals-0 ->
    //   load-callstack-0 ->
    //   load-flow-0 ->
    // step-0 <parameters> -> CompleteMove event
    //  ..

    // TaskId, EventId c-style-enums
    // rust-style enums

    //TaskKind::LoadLocals
    //TaskResult::LoadLocals(HashMap<..>) -> load-locals

    fn send_event(&mut self, event: Event) -> Result<(), Box<dyn Error>> {
        if self.indirect_send {
            self.sender.prepare_response(Response::EventResponse(event));
        } else {
            self.sender_tx.send(Response::EventResponse(event))?;
        }
        Ok(())
    }

    fn return_task(&mut self, task_result: TaskResult) -> Result<(), Box<dyn Error>> {
        if self.indirect_send {
            self.sender.prepare_response(Response::TaskResponse(task_result));
        } else {
            self.sender_tx.send(Response::TaskResponse(task_result))?;
        }
        Ok(())
    }

    pub fn get_responses_for_sending_and_clear(&mut self) -> Vec<Response> {
        let responses = self.sender.get_responses();
        self.sender.clear_responses();
        responses
    }

    pub fn configure(&mut self, arg: ConfigureArg, task: Task) -> Result<(), Box<dyn Error>> {
        self.trace = arg.trace.clone();
        self.expr_loader.trace = arg.trace.clone();
        self.flow_preloader.expr_loader.trace = arg.trace;
        self.return_void(task)?;
        Ok(())
    }

    fn load_location(&self, step_id: StepId) -> Location {
        let step_id_int = step_id.0;
        let step_record = &self.db.steps[step_id];
        let path = format!(
            "{}",
            self.db
                .workdir
                .join(self.db.load_path_from_id(&step_record.path_id))
                .display()
        );
        let line = step_record.line.0;
        let call_key = step_record.call_key;
        let call_key_int = call_key.0;

        assert!(call_key_int >= 0);

        let function_name = if step_record.call_key != NO_KEY {
            let call = &self.db.calls[call_key];
            let function = &self.db.functions[call.function_id];
            function.name.clone()
        } else {
            "<unknown>".to_string()
        };
        let call_key_text = format!("{call_key_int}");
        let global_call_key_text = format!("{}", step_record.global_call_key.0);
        let callstack_depth = 0; // TODO
        Location::new(
            &path,
            line,
            RRTicks(step_id_int),
            &function_name,
            &call_key_text,
            &global_call_key_text,
            callstack_depth,
        )
    }

    fn complete_move(&mut self, is_main: bool) -> Result<(), Box<dyn Error>> {
        let call_key = self.db.call_key_for_step(self.step_id);
        let reset_flow = is_main || call_key != self.last_call_key;
        self.last_call_key = call_key;
        let move_state = MoveState {
            status: "".to_string(),
            location: self.db.load_location(self.step_id, call_key, &mut self.expr_loader),
            c_location: Location::default(),
            main: is_main,
            reset_flow,
            stop_signal: RRGDBStopSignal::OtherStopSignal,
            frame_info: FrameInfo::default(),
        };

        // info!("move_state {:?}", move_state);
        self.send_event((
            EventKind::CompleteMove,
            gen_event_id(EventKind::CompleteMove),
            serde_json::to_string(&move_state)?,
            false,
        ))?;
        // self.send_notification(NotificationKind::Success, "Complete move!", true)?;

        let exact = false; // or for now try as flow // true just for this exact step
        let step_events = self.db.load_step_events(self.step_id, exact);
        // info!("step events for {:?} {:?}", self.step_id, step_events);
        if !step_events.is_empty() && step_events[0].kind == EventLogKind::Error {
            let error_text = &step_events[0].content;
            let error_step_id = step_events[0].step_id;
            self.send_notification(
                NotificationKind::Error,
                &format!("recorded error on step #{}: {}", error_step_id.0, error_text),
                false,
            )?;
        }
        Ok(())
    }

    pub fn start(&mut self, task: Task) -> Result<(), Box<dyn Error>> {
        // noop for db backend
        self.return_void(task)?;
        Ok(())
    }

    pub fn run_to_entry(&mut self, task: Task) -> Result<(), Box<dyn Error>> {
        self.step_id_jump(StepId(0));
        self.complete_move(true)?;
        self.return_void(task)?;
        Ok(())
    }

    pub fn load_locals(&mut self, task: Task) -> Result<(), Box<dyn Error>> {
        let full_value_locals: Vec<Variable> = self.db.variables[self.step_id]
            .iter()
            .map(|v| Variable {
                expression: self.db.variable_name(v.variable_id).to_string(),
                value: self.db.to_ct_value(&v.value),
            })
            .collect();

        // TODO: fix random order here as well: ensure order(or in final locals?)
        let value_tracking_locals: Vec<Variable> = self.db.variable_cells[self.step_id]
            .iter()
            .map(|(variable_id, place)| {
                let name = self.db.variable_name(*variable_id);
                info!("log local {variable_id:?} {name} place: {place:?}");
                let value = self.db.load_value_for_place(*place, self.step_id);
                Variable {
                    expression: self.db.variable_name(*variable_id).to_string(),
                    value: self.db.to_ct_value(&value),
                }
            })
            .collect();
        // based on https://stackoverflow.com/a/56490417/438099
        let mut locals: Vec<Variable> = full_value_locals.into_iter().chain(value_tracking_locals).collect();

        locals.sort_by(|left, right| Ord::cmp(&left.expression, &right.expression));
        // for now just removing duplicated variables/expressions: even if storing different values
        locals.dedup_by(|a, b| a.expression == b.expression);

        self.return_task((task, self.serialize(&locals)?))?;
        Ok(())
    }

    pub fn load_callstack(&mut self, task: Task) -> Result<(), Box<dyn Error>> {
        let callstack: Vec<Call> = self
            .calltrace
            .load_callstack(self.step_id, &self.db)
            .iter()
            .map(|call_record| {
                // expanded children count not relevant in raw callstack
                self.db.to_call(call_record, &mut self.expr_loader)
            })
            .collect();

        // info!("callstack {:#?}", callstack);
        self.return_task((task, self.serialize(&callstack)?))?;
        Ok(())
    }

    pub fn collapse_calls(&mut self, collapse_calls_args: CollapseCallsArgs, task: Task) -> Result<(), Box<dyn Error>> {
        if let Ok(num_key) = collapse_calls_args.call_key.clone().parse::<i64>() {
            self.calltrace.change_expand_state(CallKey(num_key), false);
        } else {
            error!("invalid i64 number for call key: {}", collapse_calls_args.call_key);
        }

        self.return_task((task, VOID_RESULT.to_string()))?;
        Ok(())
    }

    pub fn expand_calls(&mut self, collapse_calls_args: CollapseCallsArgs, task: Task) -> Result<(), Box<dyn Error>> {
        let kind = collapse_calls_args.non_expanded_kind;
        if let Ok(num_key) = collapse_calls_args.call_key.clone().parse::<i64>() {
            if kind == CalltraceNonExpandedKind::CallstackInternal {
                self.calltrace
                    .expand_callstack_internal(CallKey(num_key), collapse_calls_args.count)
            } else if kind == CalltraceNonExpandedKind::Callstack {
                self.calltrace.expand_callstack(CallKey(num_key));
            } else if kind == CalltraceNonExpandedKind::Children {
                self.calltrace.change_expand_state(CallKey(num_key), true);
            }
        } else {
            error!("invalid i64 number for call key: {}", collapse_calls_args.call_key);
        }
        self.return_task((task, VOID_RESULT.to_string()))?;
        Ok(())
    }

    fn load_local_calltrace(&mut self, args: CalltraceLoadArgs, _task: &Task) -> Result<Vec<CallLine>, Box<dyn Error>> {
        let call_key = self.db.call_key_for_step(self.step_id);
        self.calltrace.optimize_collapse = args.optimize_collapse;
        if call_key != self.calltrace.start_call_key {
            self.calltrace.jump_to(self.step_id, args.auto_collapsing, &self.db);
        }
        self.calltrace
            .load_lines(args.start_call_line_index, args.height, &self.db, &mut self.expr_loader)
    }

    fn calc_total_calls(&mut self) -> usize {
        let mut collapsed_count: usize = 0;
        for state in self.calltrace.call_states.iter() {
            if !state.expanded {
                collapsed_count += 1;
            }
        }
        self.db.calls.len() - collapsed_count
    }

    pub fn load_call_args(&mut self, args: CalltraceLoadArgs, task: Task) -> Result<(), Box<dyn Error>> {
        let start_call_line_index = args.start_call_line_index;
        let call_lines = self.load_local_calltrace(args, &task)?;
        let total_count = self.calc_total_calls();
        let position = self.calltrace.calc_scroll_position();
        let update = CallArgsUpdateResults::finished_update_call_lines(
            call_lines,
            start_call_line_index,
            total_count,
            position,
            self.calltrace.depth_offset,
        );
        self.return_task((task, VOID_RESULT.to_string()))?;
        self.send_event((
            EventKind::UpdatedCallArgs,
            gen_event_id(EventKind::UpdatedCallArgs),
            self.serialize(&update)?,
            false,
        ))?;
        Ok(())
    }

    pub fn load_flow(&mut self, location: Location, task: Task) -> Result<(), Box<dyn Error>> {
        let step_id = StepId(location.rr_ticks.0);
        let call_key = self.db.steps[step_id].call_key;
        let function_id = self.db.calls[call_key].function_id;
        let function_first = self.db.functions[function_id].line;
        let flow_update = self.flow_preloader.load(location, function_first, &self.db);
        self.return_task((task, VOID_RESULT.to_string()))?;
        self.send_event((
            EventKind::UpdatedFlow,
            gen_event_id(EventKind::UpdatedFlow),
            self.serialize(&flow_update)?,
            false,
        ))?;
        warn!("flow not finished");
        Ok(())
    }

    // we use &mut because we might process
    // an additional file in expr loader
    // in `load_location` at least
    // this is required to find out `function_first`
    // and mostly `function_last``
    #[allow(clippy::wrong_self_convention)]
    fn to_ct_calltrace_call(
        &mut self,
        db_call: &DbCall,
        depth: usize,
        depth_limit: usize,
        count_limit: usize,
    ) -> Result<(Call, usize), Box<dyn Error>> {
        // expanded children count not used here: we add actual children
        let mut call = self.db.to_call(db_call, &mut self.expr_loader);
        let mut count = 1; // our call
                           // TODO: on depth/count limit
                           // generate something like Calls non-expanded/limited
                           // similar to old isHiddenChildren / isHiddenSiblings
                           // in commented out nim calltrace user interface code
                           // instead of nothing, otherwise we're giving
                           // WRONG info which is misleading
                           //
                           // e.g. we might stop after the 2nd child of a call
                           //   with 4 children and then the interface would lead us
                           //   to think it has exactly 2 calls, instead of
                           //   2 calls and possibly non-loaded/non-expanded others more
        if depth < depth_limit && db_call.key.0 >= 0 {
            for child_call_id in &db_call.children_keys {
                assert!(child_call_id.0 >= 0);
                let (child_call, child_call_count) = self.to_ct_calltrace_call(
                    &self.db.calls[*child_call_id].clone(),
                    depth + 1,
                    depth_limit,
                    count_limit - count,
                )?;
                call.children.push(child_call);
                count += child_call_count;
                if count >= count_limit {
                    break;
                }
            }
        }
        Ok((call, count))
    }

    pub fn step_in(&mut self, forward: bool, _task: Task) -> Result<(), Box<dyn Error>> {
        self.step_id = StepId(self.single_step_line(self.step_id.0 as usize, forward) as i64);

        Ok(())
    }

    fn on_step_id_limit(&self, step_index: usize, forward: bool) -> bool {
        if forward {
            // moving forward
            step_index >= self.db.steps.len() - 1 // we're on the last one
        } else {
            // moving backwards
            step_index == 0
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

    pub fn next(&mut self, forward: bool, _task: Task) -> Result<(), Box<dyn Error>> {
        let step_to_different_line = true; // which is better/should be let the user configure it?
        (self.step_id, _) = self
            .db
            .next_step_id_relative_to(self.step_id, forward, step_to_different_line);
        Ok(())
    }

    pub fn step_out(&mut self, forward: bool, _task: Task) -> Result<(), Box<dyn Error>> {
        (self.step_id, _) = self.db.step_out_step_id_relative_to(self.step_id, forward);
        Ok(())
    }

    #[allow(clippy::expect_used)]
    pub fn step_continue(&mut self, forward: bool, _task: Task) -> Result<(), Box<dyn Error>> {
        for step in self.db.step_from(self.step_id, forward) {
            if !self.breakpoint_list.is_empty() {
                if let Some(is_active) = self.breakpoint_list[step.path_id.0]
                    .get(&step.line.into())
                    .map(|bp| bp.is_active)
                {
                    if is_active {
                        self.step_id_jump(step.step_id);
                        self.complete_move(false)?;
                        return Ok(());
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
        self.complete_move(false)?;
        self.send_notification(NotificationKind::Info, "No breakpoints were hit!", false)?;
        Ok(())
    }

    pub fn step(&mut self, arg: StepArg, task: Task) -> Result<(), Box<dyn Error>> {
        // for now not supporting repeat/skip_internal: TODO
        // TODO: reverse
        let original_step_id = self.step_id;
        // let original_step = self.db.steps[original_step_id];
        // let original_depth = self.db.calls[original_step.call_key].depth;
        match arg.action {
            Action::StepIn => self.step_in(!arg.reverse, task.clone())?,
            Action::Next => self.next(!arg.reverse, task.clone())?,
            Action::StepOut => self.step_out(!arg.reverse, task.clone())?,
            Action::Continue => self.step_continue(!arg.reverse, task.clone())?,
            _ => error!("action {:?} not implemented", arg.action),
        }
        if arg.complete && arg.action != Action::Continue {
            self.complete_move(false)?;
        }

        if original_step_id == self.step_id {
            let location = if self.step_id == StepId(0) { "beginning" } else { "end" };
            self.send_notification(
                NotificationKind::Warning,
                &format!("Limit of record at the {location} already reached!"),
                false,
            )?;
        } else if self.step_id == StepId(0) {
            self.send_notification(NotificationKind::Info, "Beginning of record reached", false)?;
        } else if self.step_id.0 as usize == self.db.steps.len() - 1 {
            self.send_notification(NotificationKind::Info, "End of record reached", false)?;
        }
        // } else if arg.action == Action::Next {
        //     let new_step = self.db.steps[self.step_id];
        //     let new_depth = self.db.calls[new_step.call_key].depth;
        //     if original_depth < new_depth {
        //         // assuming at beginning we always have depth 0, and we can't hit this situation for now hopefully
        //         if self.step_id.0 as usize == self.db.steps.len() - 1 {
        //             self.send_notification(NotificationKind::Warning, "Limit of record at the end reached!", false)?;
        //         } else {
        //             error!("next from #{original_step_id:?} ended at a deeper depth: original: {original_depth} new: {new_depth}");
        //         }
        //     }
        // }

        self.return_void(task)?;
        Ok(())
    }

    pub fn event_load(&mut self, _task: Task) -> Result<(), Box<dyn Error>> {
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

        self.event_db.register_events(DbEventKind::Record, &events, vec![-1]);
        self.event_db.refresh_global();

        self.send_event((
            EventKind::UpdatedEvents,
            gen_event_id(EventKind::UpdatedEvents),
            self.serialize(&first_events)?,
            false,
        ))?;

        self.send_event((
            EventKind::UpdatedEventsContent,
            gen_event_id(EventKind::UpdatedEventsContent),
            contents,
            true,
        ))?;

        Ok(())
    }

    pub fn event_jump(&mut self, event: ProgramEvent, task: Task) -> Result<(), Box<dyn Error>> {
        let step_id = StepId(event.direct_location_rr_ticks); // currently using this field
                                                              // for compat with rr/gdb core support
        self.step_id_jump(step_id);
        self.complete_move(false)?;

        self.return_void(task)?;
        Ok(())
    }

    pub fn calltrace_jump(&mut self, location: Location, task: Task) -> Result<(), Box<dyn Error>> {
        let step_id = StepId(location.rr_ticks.0); // using this field
                                                   // for compat with rr/gdb core support
        self.step_id_jump(step_id);
        self.complete_move(false)?;

        self.return_void(task)?;
        Ok(())
    }

    pub fn calltrace_search(&mut self, arg: CallSearchArg, task: Task) -> Result<(), Box<dyn Error>> {
        let mut calls: Vec<Call> = vec![];
        let mut list: Vec<usize> = vec![];
        let re = Regex::new(&arg.value.clone())?;

        for (id, function) in self.db.functions.iter().enumerate() {
            if re.is_match(&function.name) {
                list.push(id);
            }
        }

        for db_call in self.db.calls.clone().iter() {
            if list.contains(&db_call.function_id.0) {
                // expanded children count not relevant here
                calls.push(self.db.to_call(db_call, &mut self.expr_loader));
            }
        }

        self.return_task((task, self.serialize(&calls)?))?;
        Ok(())
    }

    fn id_to_name(&self, variable_id: VariableId) -> &String {
        &self.db.variable_names[variable_id]
    }

    pub fn load_history(&mut self, load_history_arg: LoadHistoryArg, _task: Task) -> Result<(), Box<dyn Error>> {
        let mut history_results: Vec<HistoryResult> = vec![];
        // from start to end:
        //  find all steps with such a variable name: for them:
        //    detect if the value is the same as the previous value
        //    if not: add to the history

        let current_call_key = self.db.steps[self.step_id].call_key;

        for (step_id, var_list) in self.db.variables.iter().enumerate() {
            let step = self.db.steps[StepId(step_id as i64)];
            // for now limit to current call: seems most correct
            // TODO: hopefully a more reliable value history for global search
            if step.call_key == current_call_key {
                if let Some(var) = var_list
                    .iter()
                    .find(|v| *self.id_to_name(v.variable_id) == load_history_arg.expression)
                {
                    let step_location = Location::new(
                        &load_history_arg.location.path,
                        load_history_arg.location.line,
                        // assuming usize is always safely
                        // castable as i64 on 64bit arch?
                        RRTicks(step_id as i64),
                        &load_history_arg.location.function_name,
                        &load_history_arg.location.key,
                        &load_history_arg.location.global_call_key,
                        load_history_arg.location.callstack_depth,
                    );
                    let ct_value = self.db.to_ct_value(&var.value);
                    if history_results.len() > 1 {
                        if history_results[history_results.len() - 1].value != ct_value {
                            history_results.push(HistoryResult::new(
                                step_location.clone(),
                                ct_value,
                                self.id_to_name(var.variable_id).to_string(),
                            ));
                        }
                    } else {
                        history_results.push(HistoryResult::new(
                            step_location.clone(),
                            ct_value,
                            self.id_to_name(var.variable_id).to_string(),
                        ));
                    }
                }
            }
        }

        let history_update = HistoryUpdate::new(load_history_arg.expression.clone(), &history_results);

        self.send_event((
            EventKind::UpdatedHistory,
            gen_event_id(EventKind::UpdatedHistory),
            serde_json::to_string(&history_update)?,
            false,
        ))?;

        Ok(())
    }

    pub fn history_jump(&mut self, loc: Location, task: Task) -> Result<(), Box<dyn Error>> {
        self.step_id_jump(StepId(loc.rr_ticks.0));
        self.complete_move(false)?;
        self.return_void(task)?;
        Ok(())
    }

    fn load_path_id(&self, path: &str) -> Option<PathId> {
        self.db.path_map.get(path).copied()
    }

    fn find_next_step(&self, path_id: PathId, line: usize) -> Option<StepId> {
        if let Some(records) = self.db.step_map[path_id].get(&line) {
            for record in records {
                if record.step_id > self.step_id {
                    return Some(record.step_id);
                }
            }
            return Some(records.last()?.step_id);
        }
        None
    }

    fn get_closest_step_id(&self, loc: &SourceLocation) -> Option<StepId> {
        // Check if there is a step on the line.
        let path_id = self.load_path_id(&loc.path)?;
        if let Some(step_id) = self.find_next_step(path_id, loc.line) {
            return Some(step_id);
        }

        // Get the closest step if not.
        let line_map = &self.db.step_map[path_id];
        let mut lines: Vec<&usize> = line_map.keys().collect();
        lines.sort();
        let mut closest_line: Option<usize> = None;

        for &line in lines.iter() {
            if line >= &loc.line {
                closest_line = Some(*line);
                break;
            }
        }

        if let Some(step_id) = self.find_next_step(path_id, closest_line?) {
            return Some(step_id);
        }

        // If no step found.
        None
    }

    pub fn source_line_jump(&mut self, source_location: SourceLocation, task: Task) -> Result<(), Box<dyn Error>> {
        if let Some(step_id) = self.get_closest_step_id(&source_location) {
            self.step_id_jump(step_id);
            self.complete_move(false)?;
            self.return_void(task)?;
            Ok(())
        } else {
            let err: String = format!("unknown location: {}", &source_location);
            Err(err.into())
        }
    }

    fn step_id_jump(&mut self, step_id: StepId) {
        if step_id.0 != NO_INDEX {
            self.step_id = step_id;
        }
    }

    fn get_call_target(&self, loc: &SourceCallJumpTarget) -> Option<StepId> {
        let mut line: Line = Line(loc.line as i64);
        let mut path_id: PathId = self.load_path_id(&loc.path)?;
        // TODO: eventually expose slice index? not obvious if easy
        // for now this is not often
        for step in &self.db.steps.items[(self.step_id.0 as usize)..] {
            let call = &self.db.calls[step.call_key];
            let function = &self.db.functions[call.function_id];
            if loc.token == function.name {
                line = function.line;
                path_id = function.path_id;
                break;
            }
        }

        if let Some(step_id) = self.get_closest_step_id(&SourceLocation {
            line: line.into(),
            path: self.db.load_path_from_id(&path_id).to_string(),
        }) {
            return Some(step_id);
        }

        None
    }

    pub fn source_call_jump(&mut self, call_target: SourceCallJumpTarget, task: Task) -> Result<(), Box<dyn Error>> {
        if let Some(line_step_id) = self.get_closest_step_id(&SourceLocation {
            line: call_target.line,
            path: call_target.path.clone(),
        }) {
            self.step_id_jump(line_step_id);
        }

        if let Some(call_step_id) = self.get_call_target(&call_target) {
            self.step_id_jump(call_step_id);
            self.complete_move(false)?;
            self.return_void(task)?;
            Ok(())
        } else {
            let err: String = format!("unknown call location: {}", &call_target);
            self.complete_move(false)?;
            self.send_notification(
                NotificationKind::Error,
                "Line reached but couldn't find the function!",
                false,
            )?;
            self.return_void(task)?;
            Err(err.into())
        }
    }

    pub fn add_breakpoint(&mut self, loc: SourceLocation, task: Task) -> Result<(), Box<dyn Error>> {
        let path_id_res: Result<PathId, Box<dyn Error>> = self
            .load_path_id(&loc.path)
            .ok_or(format!("can't add a breakpoint: can't find path `{}`` in trace", loc.path).into());
        let path_id = path_id_res?;
        let inner_map = &mut self.breakpoint_list[path_id.0];
        inner_map.insert(loc.line, BreakpointRecord { is_active: true });
        self.return_void(task)?;
        Ok(())
    }

    pub fn delete_breakpoint(&mut self, loc: SourceLocation, task: Task) -> Result<(), Box<dyn Error>> {
        let path_id_res: Result<PathId, Box<dyn Error>> = self
            .load_path_id(&loc.path)
            .ok_or(format!("can't add a breakpoint: can't find path `{}`` in trace", loc.path).into());
        let path_id = path_id_res?;
        let inner_map = &mut self.breakpoint_list[path_id.0];
        inner_map.remove(&loc.line);
        self.return_void(task)?;
        Ok(())
    }

    pub fn toggle_breakpoint(&mut self, loc: SourceLocation, task: Task) -> Result<(), Box<dyn Error>> {
        let path_id_res: Result<PathId, Box<dyn Error>> = self
            .load_path_id(&loc.path)
            .ok_or(format!("can't add a breakpoint: can't find path `{}`` in trace", loc.path).into());
        let path_id = path_id_res?;
        if let Some(breakpoint) = self.breakpoint_list[path_id.0].get_mut(&loc.line) {
            breakpoint.is_active = !breakpoint.is_active;
        }
        self.return_void(task)?;
        Ok(())
    }

    fn handle_trace_steps(&mut self, args: &RunTracepointsArg) -> Result<(), Box<dyn Error>> {
        let paths_count = self.db.paths.len();
        let tracepoints = args.session.tracepoints.clone();
        let mut registered = vec![false; tracepoints.len()];
        let mut tracepoint_locations = vec![HashMap::new(); paths_count];
        let mut tracepoint_errors = HashMap::new();

        // counting visits to each location, so tracepoints results
        // know that they're on the n-th iteration through the tracepoint
        let mut location_visit_indices = vec![HashMap::new(); paths_count];

        let mut interpreter = TracepointInterpreter::new(tracepoints.len());

        let mut results = vec![];

        for (i, tracepoint) in tracepoints.iter().enumerate() {
            if let Err(error) = interpreter.register_tracepoint(i, &tracepoint.expression) {
                // we won't try to evaluate this tracepoint,
                // but will continue with the other valid ones
                registered[i] = false;
                warn!("register tracepoint error: {error:?}");

                // trim quotes, adapted from https://stackoverflow.com/a/70598494/438099
                let mut error_text = format!("{:?}", error);
                if error_text.len() > 2 {
                    // assume it's `"<>"` because of Debug formatting with {:?}
                    error_text.remove(0);
                    error_text.pop();
                }
                tracepoint_errors.insert(tracepoint.tracepoint_id, error_text);

                // self.send_notification(NotificationKind::Error, &format!("Tracepoint error: {error:?}"), false)?;
            } else {
                let path_id_res: Result<PathId, Box<dyn Error>> = self.load_path_id(&tracepoint.name).ok_or(
                    format!(
                        "can't load path id for tracepoint: can't find path `{}`` in trace",
                        tracepoint.name
                    )
                    .into(),
                );
                match path_id_res {
                    Ok(path_id) => {
                        registered[i] = true;
                        tracepoint_locations[path_id.0].entry(tracepoint.line).or_insert(vec![]);
                        #[allow(clippy::unwrap_used)]
                        tracepoint_locations[path_id.0]
                            .get_mut(&tracepoint.line)
                            .unwrap()
                            .push(i);
                        location_visit_indices[path_id.0].entry(tracepoint.line).or_insert(0);
                    }
                    Err(e) => {
                        registered[i] = false;
                        warn!("tracepoint error: {e:?}");
                    }
                }
            }
        }

        let tracepoint_id_list: Vec<usize> = tracepoints.iter().map(|t| t.tracepoint_id).collect();
        self.event_db.reset_tracepoint_data(&tracepoint_id_list); // for now no smart cache non-changed optimizations(?)
        self.event_db.tracepoint_errors = tracepoint_errors.clone();

        for step in self.db.step_from(StepId(0), true) {
            let line = step.line.0 as usize;
            // let step_id_raw = step.step_id.0;
            // info!("tracepoint locations {tracepoint_locations:?} line {line} {step_id_raw}");
            if tracepoint_locations[step.path_id.0].contains_key(&line) {
                // info!("try to go through tracepoints");
                for tracepoint_index in tracepoint_locations[step.path_id.0][&line].iter() {
                    let tracepoint = &tracepoints[*tracepoint_index];
                    if registered[*tracepoint_index] {
                        // tracepoint.is_changed TODO re-enable when caching supported again
                        // info!("evaluate for {}", step.step_id.0);
                        let locals = interpreter.evaluate(*tracepoint_index, step.step_id, &self.db);
                        if locals.is_empty() {
                            continue; // assume if no logs produced, no event should be recorded
                        }
                        // info!("locals {locals:?}");
                        let stop = Stop::new(
                            self.db.load_path_from_id(&step.path_id).to_string(),
                            line as i64,
                            locals,
                            step.step_id.into(),
                            tracepoint.tracepoint_id,
                            location_visit_indices[step.path_id.0][&line],
                            StopType::Trace,
                        );
                        results.push(stop);

                        location_visit_indices[step.path_id.0]
                            .entry(line)
                            .and_modify(|e| *e += 1);

                        // if results.len() >= TRACEPOINT_RESULTS_LIMIT_BEFORE_UPDATE {
                        //     self.event_db.register_tracepoint_results(&results);
                        //     // TODO update
                        //     results.clear();
                        // }
                    }
                }
            }
        }

        // if !results.is_empty() {
        self.event_db.register_tracepoint_results(&results);
        // }

        // for (i, tracepoint) in tracepoints.iter().enumerate() {
        //     if tracepoint.is_changed && registered[i] {
        //         let mut results: Vec<Stop> = vec![];
        //         let path_id_res: Result<PathId, Box<dyn Error>> = self
        //             .load_path_id(&tracepoint.name)
        //             .ok_or(format!("path not found in trace: {}", tracepoint.name).into());
        //         let path_id = path_id_res?;
        //         if let Some(steps) = self.db.step_map[path_id].get(&tracepoint.line) {
        //             for (update_id, step) in steps.iter().enumerate() {
        //                 // log(i);
        //                 // log(other + i); "other + i" => #<line,column>:
        //                 // log(i, other); [(i, i value), (name: text, value: othe)]
        //                 let locals = interpreter.evaluate(i, self.step_id, &self.db);

        //                 results.push(Stop::new(
        //                     self.db.load_path_from_id(&step.path_id).to_string(),
        //                     step.line.0,
        //                     locals.clone(),
        //                     step.step_id.into(),
        //                     tracepoint.tracepoint_id,
        //                     update_id,
        //                     StopType::Trace,
        //                 ));
        //             }
        //         }
        //         let mut locals: Vec<StringAndValueTuple> = vec![];
        //         for res in results.iter() {
        //             locals.extend(res.locals.clone());
        //         }
        // self.event_db
        //     .register_tracepoint_values(tracepoint.tracepoint_id, locals.clone());
        // let pe_list = self.trace_to_program_event(&results);
        // let tracepoint_ids = self.get_tracepoint_ids(&results);
        // self.event_db
        // .register_events(DbEventKind::Trace, &pe_list, tracepoint_ids);
        // self.event_db.refresh_global();
        // Send update to frontend
        Ok(())
    }

    pub fn run_tracepoints(&mut self, args: RunTracepointsArg, _task: Task) -> Result<(), Box<dyn Error>> {
        // Sort steps in StepId Ord
        self.setup_trace_session(
            args.clone(),
            Task {
                kind: TaskKind::SetupTraceSession,
                id: gen_task_id(TaskKind::SetupTraceSession),
            },
        )?;

        let tracepoints = &args.session.tracepoints;
        let is_empty = false; // TODO: check if there is at least one enabled non-empty log?

        if !is_empty {
            // Handle id_table and results for the TraceUpdate
            self.handle_trace_steps(&args)?;
        }
        for trace in tracepoints.iter() {
            let trace_update = TraceUpdate::new(
                args.session.id,
                true,
                trace.tracepoint_id,
                self.event_db.tracepoint_errors.clone(),
            );
            self.send_event((
                EventKind::UpdatedTrace,
                gen_event_id(EventKind::UpdatedTrace),
                self.serialize(&trace_update)?,
                false,
            ))?;
        }
        // } else {
        //     for trace in tracepoints.iter() {
        //         let trace_update = TraceUpdate::new(args.session.id, true, trace.tracepoint_id);
        //         // trace_update.tracepoint_errors
        //         self.send_event((
        //             EventKind::UpdatedTrace,
        //             gen_event_id(EventKind::UpdatedTrace),
        //             self.serialize(&trace_update)?,
        //             false,
        //         ))?;
        //     }
        // }

        // Send update to frontend

        Ok(())
    }

    pub fn trace_jump(&mut self, event: ProgramEvent, task: Task) -> Result<(), Box<dyn Error>> {
        self.step_id_jump(StepId(event.direct_location_rr_ticks));
        self.complete_move(false)?;
        self.return_void(task)?;
        Ok(())
    }

    pub fn tracepoint_delete(&mut self, tracepoint_id: TracepointId, task: Task) -> Result<(), Box<dyn Error>> {
        self.event_db.clear_single_table(SingleTableId(tracepoint_id.id + 1));
        self.event_db.refresh_global();
        let mut t_update = TraceUpdate::new(0, false, tracepoint_id.id, self.event_db.tracepoint_errors.clone());
        t_update.refresh_event_log = true;
        self.send_event((
            EventKind::UpdatedTrace,
            gen_event_id(EventKind::UpdatedTrace),
            self.serialize(&t_update)?,
            false,
        ))?;
        self.return_void(task)?;
        Ok(())
    }

    pub fn tracepoint_toggle(&mut self, tracepoint_id: TracepointId, task: Task) -> Result<(), Box<dyn Error>> {
        let table_id = self.event_db.make_single_table_id(tracepoint_id.id);
        if self.event_db.disabled_tables.contains(&table_id) {
            self.event_db.enable_table(table_id);
        } else {
            self.event_db.disable_table(table_id);
        }
        self.event_db.refresh_global();
        let mut t_update = TraceUpdate::new(0, false, tracepoint_id.id, self.event_db.tracepoint_errors.clone());
        t_update.refresh_event_log = true;
        self.send_event((
            EventKind::UpdatedTrace,
            gen_event_id(EventKind::UpdatedTrace),
            self.serialize(&t_update)?,
            false,
        ))?;
        self.return_void(task)?;
        Ok(())
    }

    pub fn search_program(&mut self, query: String, task: Task) -> Result<(), Box<dyn Error>> {
        let program_search_tool = ProgramSearchTool::new(&self.db);
        let results = program_search_tool.search(&query, &mut self.expr_loader)?;
        self.send_event((
            EventKind::ProgramSearchResults,
            gen_event_id(EventKind::ProgramSearchResults),
            self.serialize(&results)?,
            false,
        ))?;
        self.return_void(task)?;
        Ok(())
    }

    pub fn load_step_lines(&mut self, arg: LoadStepLinesArg, task: Task) -> Result<(), Box<dyn Error>> {
        let step_lines = vec![];
        // self.step_lines_loader.load_lines(
        //     &arg.location,
        //     arg.backward_count,
        //     arg.forward_count,
        //     &self.db,
        //     &mut self.flow_preloader,
        // );
        let step_lines_update = LoadStepLinesUpdate {
            results: step_lines,
            arg_location: arg.location,
            finish: true,
        };
        self.send_event((
            EventKind::UpdatedLoadStepLines,
            gen_event_id(EventKind::UpdatedLoadStepLines),
            self.serialize(&step_lines_update)?,
            false,
        ))?;
        self.return_void(task)?;
        Ok(())
    }

    pub fn local_step_jump(&mut self, arg: LocalStepJump, task: Task) -> Result<(), Box<dyn Error>> {
        self.step_id_jump(StepId(arg.rr_ticks));
        self.complete_move(false)?;
        self.return_void(task)?;
        Ok(())
    }

    pub fn register_events(&mut self, arg: RegisterEventsArg, task: Task) -> Result<(), Box<dyn Error>> {
        self.event_db.register_events(arg.kind, &arg.events, vec![-1]);
        self.event_db.refresh_global();
        self.return_void(task)?;
        Ok(())
    }

    pub fn setup_trace_session(&mut self, arg: RunTracepointsArg, task: Task) -> Result<(), Box<dyn Error>> {
        for trace in arg.session.tracepoints {
            while trace.tracepoint_id + 1 >= self.event_db.single_tables.len() {
                self.event_db.add_new_table(DbEventKind::Trace, &[]);
            }
            assert!(self.event_db.single_tables.len() > trace.tracepoint_id + 1);
        }
        self.return_void(task)?;
        Ok(())
    }

    pub fn register_tracepoint_logs(&mut self, arg: TracepointResults, task: Task) -> Result<(), Box<dyn Error>> {
        self.event_db
            .register_tracepoint_values(arg.tracepoint_id, arg.tracepoint_values);
        self.event_db
            .register_events(DbEventKind::Trace, &arg.events, vec![arg.tracepoint_id as i64]);
        self.event_db.refresh_global();

        let trace_count = self.event_db.get_trace_length(arg.tracepoint_id);
        let total_count = self.event_db.get_events_count();

        let mut trace_update = TraceUpdate::new(
            arg.session_id,
            arg.first_update,
            arg.tracepoint_id,
            self.event_db.tracepoint_errors.clone(),
        );
        trace_update.total_count = total_count;
        trace_update.count = trace_count;
        trace_update.update_id = arg.tracepoint_id;
        self.send_event((
            EventKind::UpdatedTrace,
            gen_event_id(EventKind::UpdatedTrace),
            self.serialize(&trace_update)?,
            false,
        ))?;
        self.return_void(task)?;
        Ok(())
    }

    pub fn update_table(&mut self, args: UpdateTableArgs, task: Task) -> Result<(), Box<dyn Error>> {
        let (table_update, trace_values_option) = self.event_db.update_table(args)?;
        if let Some(trace_values) = trace_values_option {
            self.send_event((
                EventKind::TracepointLocals,
                gen_event_id(EventKind::TracepointLocals),
                self.serialize(&trace_values)?,
                false,
            ))?;
        }
        // info!("table update {:?}", table_update);

        self.send_event((
            EventKind::UpdatedTable,
            gen_event_id(EventKind::UpdatedTable),
            self.serialize(&table_update)?,
            false,
        ))?;
        self.return_void(task)?;
        Ok(())
    }

    fn load_steps_for_call(&mut self, call_key: CallKey) -> IndexMap<i64, StepId> {
        let mut list: IndexMap<i64, StepId> = IndexMap::default();
        let db_call = &self.db.calls[call_key];
        let function_step = self.db.steps[db_call.step_id];
        let location = self.load_location(db_call.step_id);
        let function_location = self
            .flow_preloader
            .expr_loader
            .find_function_location(&location, &function_step.line);
        for line in function_location.function_first..function_location.function_last {
            let function_id = &self.db.functions[db_call.function_id];
            let step_map = &self.db.step_map[function_id.path_id];
            if let Some(steps) = step_map.get(&(line as usize)) {
                for step in steps {
                    if step.call_key == call_key {
                        if !list.contains_key(&line) {
                            info!(
                                "----- Not a loop here enter Line({:?}) and StepId - {:?}",
                                line, step.step_id
                            );
                            list.insert(line, step.step_id);
                        } else if step.step_id >= self.step_id {
                            list.entry(line)
                                .and_modify(|e| *e = step.step_id)
                                .or_insert(step.step_id);
                            // We change the line entry and break because we have found the next closest
                            info!(
                                "----- because of the loop we change here Line({:?}) with StepId - {:?}",
                                line, step.step_id
                            );
                            break;
                        }
                    }
                }
            } else {
                list.insert(line, StepId(-1));
            }
        }
        list
    }

    pub fn load_asm_function(&mut self, args: FunctionLocation, task: Task) -> Result<(), Box<dyn Error>> {
        let mut instructions: Vec<Instruction> = vec![];
        match args.key.parse::<i64>() {
            Ok(number) => {
                let call_key = CallKey(number);
                let interesting_steps = self.load_steps_for_call(call_key);
                for (line, step_id) in interesting_steps.iter() {
                    if step_id.0 != NO_STEP_ID {
                        let current_step = self.db.steps[*step_id];
                        if let Some(asm_instructions) = self.db.instructions.get(*step_id) {
                            if asm_instructions.is_empty() {
                                instructions.push(Instruction::empty(
                                    *line,
                                    self.db.load_path_from_id(&current_step.path_id),
                                    step_id.0,
                                ))
                            }
                            for arg in asm_instructions {
                                instructions.push(Instruction {
                                    args: "".to_string(),
                                    high_level_line: *line,
                                    high_level_path: self.db.load_path_from_id(&current_step.path_id).to_string(),
                                    name: arg.to_string(),
                                    offset: current_step.step_id.0,
                                    other: "".to_string(),
                                });
                            }
                        }
                    } else {
                        instructions.push(Instruction::empty(
                            *line,
                            self.db
                                .load_path_from_id(&self.db.functions[self.db.calls[call_key].function_id].path_id),
                            NO_STEP_ID,
                        ))
                    }
                }
                let instructions: Instructions = Instructions {
                    address: 0,
                    instructions,
                    error: "".to_string(),
                };
                self.return_task((task, self.serialize(&instructions)?))?;
                Ok(())
            }
            Err(e) => Err(Box::new(e)),
        }
    }

    pub fn load_terminal(&mut self, task: Task) -> Result<(), Box<dyn Error>> {
        let mut events_list: Vec<ProgramEvent> = vec![];
        for (i, event_record) in self.db.events.iter().enumerate() {
            if event_record.kind == EventLogKind::Write {
                events_list.push(self.to_program_event(event_record, i));
            }
        }
        self.send_event((
            EventKind::LoadedTerminal,
            gen_event_id(EventKind::LoadedTerminal),
            self.serialize(&events_list)?,
            false,
        ))?;
        self.return_void(task)?;
        Ok(())
    }

    fn send_notification(
        &mut self,
        kind: NotificationKind,
        msg: &str,
        is_operation_status: bool,
    ) -> Result<(), Box<dyn Error>> {
        let notification = Notification::new(kind, msg, is_operation_status);
        self.send_event((
            EventKind::NewNotification,
            gen_event_id(EventKind::NewNotification),
            self.serialize(&notification)?,
            false,
        ))?;
        Ok(())
    }

    fn return_void(&mut self, task: Task) -> Result<(), Box<dyn Error>> {
        self.return_task((task, VOID_RESULT.to_string()))
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
            filename_metadata: "".to_string(),
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

    fn serialize<T: Serialize>(&self, value: &T) -> Result<String, Box<dyn Error>> {
        let res = serde_json::to_string(value)?;
        Ok(res)
    }
}

#[cfg(test)]
mod tests {
    use std::env;
    use std::path::{Path, PathBuf};
    use std::sync::mpsc;

    use super::*;
    // use crate::event_db;
    use crate::lang;
    use crate::task;
    use crate::task::{gen_task_id, GlobalCallLineIndex};
    use crate::trace_processor::{load_trace_data, load_trace_metadata, TraceProcessor};
    use clap::error::Result;
    // use event_db::{IndexInSingleTable, SingleTableId};
    // use futures::stream::Iter;
    use lang::Lang;
    use runtime_tracing::{
        CallRecord, FieldTypeRecord, FunctionId, FunctionRecord, StepId, StepRecord, TraceLowLevelEvent, TraceMetadata,
        Tracer, TypeId, TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord, NONE_VALUE,
    };

    use task::{TaskId, TaskKind, TraceSession, Tracepoint, TracepointMode};

    #[test]
    fn test_struct_handling() {
        let db = setup_db();
        let (sender_tx, _receiver_rx) = mpsc::channel();
        let handler: Handler = Handler::new(Box::new(db), sender_tx.clone());
        let value = handler.db.to_ct_value(&ValueRecord::Struct {
            field_values: vec![],
            type_id: TypeId(1),
        });
        assert_eq!(value.typ.labels, ["a".to_string()]);
    }
    #[test]
    fn test_handler_new() {
        // Arrange: Create a Db instance and an mpsc channel
        let db = setup_db();

        let (sender_tx, _receiver_rx) = mpsc::channel();

        // Act: Create a new Handler instance
        let handler: Handler = Handler::new(Box::new(db), sender_tx.clone());

        // Assert: Check that the Handler instance is correctly initialized
        assert_eq!(handler.step_id, StepId(0));
        assert!(!handler.breakpoint_list.is_empty());
    }

    // Test single tracepoint
    #[test]
    fn test_run_single_tracepoint() -> Result<(), Box<dyn Error>> {
        let db = setup_db();
        let (sender_tx, _receiver_rx) = mpsc::channel();
        let mut handler: Handler = Handler::new(Box::new(db), sender_tx.clone());
        handler.event_load(Task {
            kind: TaskKind::EventLoad,
            id: TaskId("0".to_string()),
        })?;
        handler.run_tracepoints(
            make_tracepoints_args(1, 0),
            Task {
                kind: TaskKind::RunTracepoints,
                id: TaskId("1".to_string()),
            },
        )?;
        assert_eq!(handler.event_db.single_tables.len(), 2);
        Ok(())
    }

    // Test basic multiple tracepoints
    #[test]
    fn test_multiple_tracepoints() -> Result<(), Box<dyn Error>> {
        let db = setup_db();
        let (sender_tx, _receiver_rx) = mpsc::channel();
        let mut handler: Handler = Handler::new(Box::new(db), sender_tx.clone());
        handler.event_load(Task {
            kind: TaskKind::EventLoad,
            id: TaskId("0".to_string()),
        })?;
        // TODO
        // this way we are resetting them after reforms
        // needs to pass multiple tracepoints at once now
        // handler.run_tracepoints(
        //     make_tracepoints_args(3, 0),
        //     Task {
        //         kind: TaskKind::RunTracepoints,
        //         id: TaskId("1".to_string()),
        //     },
        // )?;
        // handler.run_tracepoints(
        //     make_tracepoints_args(2, 1),
        //     Task {
        //         kind: TaskKind::RunTracepoints,
        //         id: TaskId("2".to_string()),
        //     },
        // )?;
        // handler.run_tracepoints(
        //     make_tracepoints_args(1, 2),
        //     Task {
        //         kind: TaskKind::RunTracepoints,
        //         id: TaskId("3".to_string()),
        //     },
        // )?;
        // assert_eq!(handler.event_db.single_tables.len(), 4);
        // assert_eq!(handler.event_db.global_table.len(), 3);
        // assert_eq!(
        //     handler.event_db.global_table,
        //     vec![
        //         (StepId(0), SingleTableId(3), IndexInSingleTable(0)),
        //         (StepId(1), SingleTableId(2), IndexInSingleTable(0)),
        //         (StepId(2), SingleTableId(1), IndexInSingleTable(0))
        //     ]
        // );
        Ok(())
    }

    // pass size to produce multiline multiple log(expr) to log on a step
    #[test]
    fn test_multile_tracepoints_with_multiline_logs() -> Result<(), Box<dyn Error>> {
        let size: usize = 10000;
        let db: Db = setup_db();
        let (sender_tx, _receiver_rx) = mpsc::channel();
        let mut handler: Handler = Handler::new(Box::new(db), sender_tx.clone());
        handler.event_load(Task {
            kind: TaskKind::EventLoad,
            id: TaskId("0".to_string()),
        })?;
        handler.run_tracepoints(
            make_multiple_tracepoints_with_multiline_logs(3, size),
            Task {
                kind: TaskKind::RunTracepoints,
                id: TaskId("1".to_string()),
            },
        )?;
        assert_eq!(handler.event_db.single_tables.len(), 4);
        // TODO(alexander): debug what's happening here

        // assert_eq!(handler.event_db.global_table.len(), 3);
        // assert_eq!(
        //     handler.event_db.global_table,
        //     vec![
        //         (StepId(0), SingleTableId(1), IndexInSingleTable(0)),
        //         (StepId(1), SingleTableId(2), IndexInSingleTable(0)),
        //         (StepId(2), SingleTableId(3), IndexInSingleTable(0))
        //     ]
        // );
        Ok(())
    }

    // Test a tracepoint on a loop line
    #[test]
    #[ignore]
    fn test_tracepoint_in_loop() -> Result<(), Box<dyn Error>> {
        let size = 10000;
        let db: Db = setup_db_loop(size);
        let (sender_tx, _receiver_rx) = mpsc::channel();
        let mut handler: Handler = Handler::new(Box::new(db), sender_tx.clone());
        handler.event_load(Task {
            kind: TaskKind::EventLoad,
            id: TaskId("0".to_string()),
        })?;
        handler.run_tracepoints(
            make_tracepoints_args(2, 0),
            Task {
                kind: TaskKind::RunTracepoints,
                id: TaskId("1".to_string()),
            },
        )?;
        assert_eq!(handler.event_db.single_tables[1].events.len(), size);
        Ok(())
    }

    // Test a given number of steps with individual tracepoint on each
    #[test]
    #[ignore]
    fn test_big_number_tracepoints() -> Result<(), Box<dyn Error>> {
        // Number of tracepoints and steps
        let count: usize = 10000;
        let db: Db = setup_db_with_step_count(count);
        let (sender_tx, _receiver_rx) = mpsc::channel();
        let mut handler: Handler = Handler::new(Box::new(db), sender_tx.clone());
        handler.event_load(Task {
            kind: TaskKind::EventLoad,
            id: TaskId("0".to_string()),
        })?;
        handler.run_tracepoints(
            make_tracepoints_with_count(count),
            Task {
                kind: TaskKind::RunTracepoints,
                id: TaskId("1".to_string()),
            },
        )?;

        assert_eq!(handler.event_db.single_tables.len(), count + 1);
        Ok(())
    }

    #[test]
    fn test_step_in() -> Result<(), Box<dyn Error>> {
        let db = setup_db();

        let (sender_tx, _receiver_rx) = mpsc::channel();

        // Act: Create a new Handler instance
        let mut handler: Handler = Handler::new(Box::new(db), sender_tx.clone());
        handler.step(
            make_step_in(),
            Task {
                kind: TaskKind::Step,
                id: TaskId("0".to_string()),
            },
        )?;
        assert_eq!(handler.step_id, StepId(1_i64));
        Ok(())
    }

    #[test]
    fn test_source_jumps() -> Result<(), Box<dyn Error>> {
        let db = setup_db();
        let (sender_tx, _receiver_rx) = mpsc::channel();
        let mut handler: Handler = Handler::new(Box::new(db), sender_tx.clone());
        let path = "/test/workdir";
        let source_location: SourceLocation = SourceLocation {
            path: path.to_string(),
            line: 3,
        };
        handler.source_line_jump(
            source_location,
            Task {
                kind: TaskKind::SourceLineJump,
                id: TaskId("0".to_string()),
            },
        )?;
        assert_eq!(handler.step_id, StepId(2));
        handler.source_line_jump(
            SourceLocation {
                path: path.to_string(),
                line: 2,
            },
            Task {
                kind: TaskKind::SourceLineJump,
                id: TaskId("1".to_string()),
            },
        )?;
        assert_eq!(handler.step_id, StepId(1));
        handler.source_call_jump(
            SourceCallJumpTarget {
                path: "/test/workdir".to_string(),
                line: 1,
                token: "<top-level>".to_string(),
            },
            Task {
                kind: TaskKind::SourceCallJump,
                id: TaskId("0".to_string()),
            },
        )?;
        assert_eq!(handler.step_id, StepId(0));
        Ok(())
    }

    #[test]
    fn test_local_calltrace() -> Result<(), Box<dyn Error>> {
        let db = setup_db_with_calls();
        let (sender_tx, _receiver_rx) = mpsc::channel();
        let mut handler: Handler = Handler::new(Box::new(db), sender_tx.clone());

        let calltrace_load_args = CalltraceLoadArgs {
            location: handler
                .db
                .load_location(StepId(4), CallKey(-1), &mut handler.expr_loader),
            start_call_line_index: GlobalCallLineIndex(0),
            depth: 10,
            height: 10,
            raw_ignore_patterns: "".to_string(),
            auto_collapsing: true,
            optimize_collapse: true,
        };
        let _call_lines = handler.load_local_calltrace(
            calltrace_load_args,
            &Task {
                kind: TaskKind::LoadCallArgs,
                id: TaskId("load-call-args-0".to_string()),
            },
        )?;

        // assert_eq!(parent_key, CallKey(0));
        // assert_eq!(calltrace.location.key, "1".to_string());
        // assert_eq!(calltrace.children.len(), 2);
        // let call_a = &calltrace.children[0];
        // let call_b = &calltrace.children[1];
        // assert_eq!(call_a.location.function_name, "a".to_string());
        // assert_eq!(call_a.location.key, "2".to_string());
        // assert_eq!(call_b.location.function_name, "b".to_string());
        // assert_eq!(call_b.location.key, "3".to_string());

        Ok(())
    }

    #[test]
    fn test_valid_trace() {
        // can be called from just test-valid-trace <my-trace-dir>
        // calling inside db-backend
        // env CODETRACER_VALID_TEST_TRACE_DIR=<trace-dir> cargo test test_valid_trace
        let raw_path = env::var("CODETRACER_VALID_TEST_TRACE_DIR").unwrap_or("".to_string());
        if raw_path.is_empty() {
            // assume called as part of normal tests or by mistake: just don't do anything and return
            return;
        }
        let path = &PathBuf::from(raw_path);
        // (&PathBuf::from("/home/alexander92/codetracer-desktop/src/db-backend/example-trace/")
        let db = load_db_for_trace(path);
        let (sender_tx, _receiver_rx) = mpsc::channel();
        let mut handler: Handler = Handler::new(Box::new(db), sender_tx.clone());

        // step-in from 1 to end(maybe also a parameter?)
        // on each step check validity, load locals, load callstack
        // eventually: loading local calltrace? or at least for first real call?
        // eventually: loading flow for new calls?
        // first version loading locals/callstack
        test_step_in_scenario(&mut handler, path);
    }

    fn test_load_flow(handler: &mut Handler, _path: &PathBuf) {
        handler
            .load_flow(handler.load_location(handler.step_id), gen_task(TaskKind::LoadFlow))
            .unwrap();
    }

    fn test_step_in_scenario(handler: &mut Handler, path: &PathBuf) {
        for i in 0..handler.db.steps.len() - 1 {
            // eprintln!("doing step-in {i}");
            handler.step_in(true, gen_task(TaskKind::Step)).unwrap();
            assert_eq!(handler.step_id, StepId(i as i64 + 1));
            test_load_locals(handler);
            test_load_callstack(handler);
            test_load_flow(handler, path);
        }
    }

    fn test_load_locals(handler: &mut Handler) {
        handler.load_locals(gen_task(TaskKind::LoadLocals)).unwrap();
    }

    fn test_load_callstack(handler: &mut Handler) {
        handler.load_callstack(gen_task(TaskKind::LoadCallstack)).unwrap();
    }

    fn gen_task(kind: TaskKind) -> Task {
        Task {
            kind,
            id: gen_task_id(kind),
        }
    }
    fn load_db_for_trace(path: &Path) -> Db {
        let trace_file = path.join("trace.json");
        let trace_metadata_file = path.join("trace_metadata.json");
        let trace = load_trace_data(&trace_file).expect("expected that it can load the trace file");
        let trace_metadata =
            load_trace_metadata(&trace_metadata_file).expect("expected that it can load the trace metadata file");
        let mut db = Db::new(&trace_metadata.workdir);
        let mut trace_processor = TraceProcessor::new(&mut db);
        trace_processor.postprocess(&trace).unwrap();
        db
    }

    fn setup_db() -> Db {
        // TODO: maybe source from a real program trace?
        let none_type = TypeRecord {
            kind: TypeKind::None,
            lang_type: "None".to_string(),
            specific_info: TypeSpecificInfo::None,
        };
        let struct_type = TypeRecord {
            kind: TypeKind::Struct,
            lang_type: "ExampleStruct".to_string(),
            specific_info: TypeSpecificInfo::Struct {
                fields: vec![FieldTypeRecord {
                    name: "a".to_string(),
                    type_id: TypeId(0),
                }],
            },
        };

        let trace: Vec<TraceLowLevelEvent> = vec![
            TraceLowLevelEvent::Path(PathBuf::from("/test/workdir")),
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(1),
                name: "<top-level>".to_string(),
            }),
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(0),
                args: vec![],
            }),
            TraceLowLevelEvent::Type(none_type),
            TraceLowLevelEvent::Type(struct_type),
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(1),
            }),
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(2),
            }),
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(3),
            }),
        ];
        let trace_metadata = TraceMetadata {
            workdir: PathBuf::from("/test/workdir"),
            program: "test".to_string(),
            args: vec![],
        };
        let mut db = Db::new(&trace_metadata.workdir);
        let mut trace_processor = TraceProcessor::new(&mut db);
        trace_processor.postprocess(&trace).unwrap();

        // eprintln!("{:#?}", db);
        db
    }

    fn setup_db_with_calls() -> Db {
        // TODO: maybe source from a real program trace?
        let mut tracer = Tracer::new("example.small", &[]);
        let path = &PathBuf::from("/test/workdir/example.small");
        tracer.start(path, Line(1));
        tracer.register_step(path, Line(1));
        tracer.register_step(path, Line(2));
        tracer.register_step(path, Line(3));

        tracer.register_step(path, Line(4));
        let start_function_id = tracer.ensure_function_id("start", path, Line(4));
        tracer.register_call(start_function_id, vec![]);

        tracer.register_step(path, Line(5));

        tracer.register_step(path, Line(7));
        let a_function_id = tracer.ensure_function_id("a", path, Line(7));
        tracer.register_call(a_function_id, vec![]);
        tracer.register_step(path, Line(8));
        tracer.register_return(NONE_VALUE);

        tracer.register_step(path, Line(6));
        let b_function_id = tracer.ensure_function_id("b", path, Line(10));
        tracer.register_call(b_function_id, vec![]);
        tracer.register_step(path, Line(11));
        tracer.register_return(NONE_VALUE);

        let trace_metadata = TraceMetadata {
            workdir: PathBuf::from("/test/workdir"),
            program: "example.small".to_string(),
            args: vec![],
        };

        let mut db = Db::new(&trace_metadata.workdir);
        let mut trace_processor = TraceProcessor::new(&mut db);
        trace_processor.postprocess(&tracer.events).unwrap();

        // eprintln!("{:#?}", db);
        db
    }

    fn setup_db_loop(size: usize) -> Db {
        let loop_steps = vec![
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(2),
            }),
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(3),
            }),
        ];
        let mut trace: Vec<TraceLowLevelEvent> = vec![
            TraceLowLevelEvent::Path(PathBuf::from("/test/workdir")),
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(1),
                name: "<top-level".to_string(),
            }),
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(0),
                args: vec![],
            }),
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(1),
            }),
        ];
        for _ in 0..size {
            trace.extend(loop_steps.clone())
        }
        let trace_metadata = TraceMetadata {
            workdir: PathBuf::from("/test/workdir"),
            program: "test".to_string(),
            args: vec![],
        };
        let mut db = Db::new(&trace_metadata.workdir);
        let mut trace_processor = TraceProcessor::new(&mut db);
        trace_processor.postprocess(&trace).unwrap();
        db
    }

    // Alternative Db setup
    fn setup_db_with_step_count(count: usize) -> Db {
        let mut events: Vec<TraceLowLevelEvent> = vec![];
        events.extend(vec![
            TraceLowLevelEvent::Path(PathBuf::from("/test/workdir")),
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(1),
                name: "<top-level".to_string(),
            }),
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(0),
                args: vec![],
            }),
        ]);
        for i in 0..count {
            events.push(TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(i as i64 + 1),
            }));
        }
        let trace = events;
        let trace_metadata = TraceMetadata {
            workdir: PathBuf::from("/test/workdir"),
            program: "test".to_string(),
            args: vec![],
        };
        let mut db = Db::new(&trace_metadata.workdir);
        let mut trace_processor = TraceProcessor::new(&mut db);
        trace_processor.postprocess(&trace).unwrap();

        // eprintln!("{:#?}", db);
        db
    }

    fn make_step_in() -> StepArg {
        StepArg {
            action: Action::StepIn,
            reverse: false,
            repeat: 0,
            complete: true,
            skip_internal: true,
            skip_no_source: false,
        }
    }

    // Individual tracesessions for earch tracepoint
    fn make_tracepoints_args(line: usize, id: usize) -> RunTracepointsArg {
        RunTracepointsArg {
            session: TraceSession {
                tracepoints: vec![Tracepoint {
                    tracepoint_id: id,
                    mode: TracepointMode::TracInlineCode,
                    line,
                    offset: -1,
                    is_changed: true,
                    name: "/test/workdir".to_string(),
                    expression: "log(test)".to_string(),
                    last_render: 0,
                    is_disabled: false,
                    lang: Lang::Unknown,
                    results: vec![],
                    tracepoint_error: "".to_string(),
                }],
                found: vec![],
                last_count: 0,
                results: HashMap::default(),
                id: 0,
            },
            stop_after: 0,
        }
    }

    // One TraceSession with a Vec<Tracepoint>
    fn make_tracepoints_with_count(count: usize) -> RunTracepointsArg {
        let mut tracepoints: Vec<Tracepoint> = vec![];
        for i in 0..count {
            tracepoints.push(Tracepoint {
                tracepoint_id: i,
                mode: TracepointMode::TracInlineCode,
                line: i + 1,
                offset: -1,
                is_changed: true,
                name: "/test/workdir".to_string(),
                expression: "log(test)".to_string(),
                last_render: 0,
                is_disabled: false,
                lang: Lang::Unknown,
                results: vec![],
                tracepoint_error: "".to_string(),
            });
        }

        RunTracepointsArg {
            session: TraceSession {
                tracepoints,
                found: vec![],
                last_count: 0,
                results: HashMap::default(),
                id: 0,
            },
            stop_after: 0,
        }
    }

    // One TraceSession with a Vec<Tracepoint>
    fn make_multiple_tracepoints_with_multiline_logs(iterations: usize, size: usize) -> RunTracepointsArg {
        let mut tracepoints: Vec<Tracepoint> = vec![];
        let mut expression: String = "".to_string();
        for _ in 0..size {
            expression += "log(asd)\n"
        }
        for i in 0..iterations {
            tracepoints.push(Tracepoint {
                tracepoint_id: i,
                mode: TracepointMode::TracInlineCode,
                line: i + 1,
                offset: -1,
                is_changed: true,
                name: "/test/workdir".to_string(),
                expression: expression.to_string(),
                last_render: 0,
                is_disabled: false,
                lang: Lang::Unknown,
                results: vec![],
                tracepoint_error: "".to_string(),
            });
        }

        RunTracepointsArg {
            session: TraceSession {
                tracepoints,
                found: vec![],
                last_count: 0,
                results: HashMap::default(),
                id: 0,
            },
            stop_after: 0,
        }
    }
}

// TODO:
// * load-locals
//   * convert ValueRecord to Value
//   * optionally more kinds of Values
// * event-load/event jump
// * stepping/line jump
//   * step-in
//   * step-out
//   * next (and same for reverse but back)
// * ?break/continue
// * ?callstack/calltrace
//   * eventually if non-full traces, direct callstack in trace?
//   * fuller calltrace interface? maybe discuss with team?
//   * multiple trees if separate parts recorded?
// * ?filters
//   * eventually ct libs used inside programs?
// * build/MR/try?
// * languages:
//   * python/nim/php/java/perl/lua/javascript/other
//
// * later potentially:
//   * tracepoint?
//     * for now maybe only existing locals/combos of them e.g. a.b
//   * flow
//     * for now extracting just more for names on each line
//     * eventually a mini-lib for branches/loops from rust and logic
//       * reuse from python? or for now have 2 impls?
//   * multi-process:
//     * process/thread id
//     * different calltraces/callstacks based on that
//     * eventually jumps/phases?
// * potentially later in future:
//   * queries: e.g. if variable > 5 and in calltree x
//   * exceptions/signal/return values more special
//   * async?
