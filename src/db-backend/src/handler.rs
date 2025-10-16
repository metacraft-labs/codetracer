use indexmap::IndexMap;
use std::collections::HashMap;
use std::error::Error;

use log::{error, info, warn};
use regex::Regex;
use serde::Serialize;

use runtime_tracing::{CallKey, EventLogKind, Line, PathId, StepId, VariableId, NO_KEY};

use crate::calltrace::Calltrace;
use crate::dap::{self, DapClient, DapMessage};
use crate::db::{Db, DbCall, DbRecordEvent, DbReplay, DbStep};
use crate::event_db::{EventDb, SingleTableId};
use crate::expr_loader::ExprLoader;
use crate::flow_preloader::FlowPreloader;
use crate::program_search_tool::ProgramSearchTool;
use crate::replay::Replay;
use crate::rr_dispatcher::{CtRRArgs, RRDispatcher};
// use crate::response::{};
use crate::dap_types;
// use crate::dap_types::Source;
use crate::step_lines_loader::StepLinesLoader;
use crate::task;
use crate::task::{
    Action, Breakpoint, Call, CallArgsUpdateResults, CallLine, CallSearchArg, CalltraceLoadArgs, CalltraceNonExpandedKind,
    CollapseCallsArgs, CoreTrace, DbEventKind, FrameInfo, FunctionLocation, FlowMode, HistoryResult, HistoryUpdate, Instruction,
    CtLoadFlowArguments, FlowUpdate, Instructions, LoadHistoryArg, LoadStepLinesArg, LoadStepLinesUpdate, LocalStepJump, Location, MoveState,
    Notification, NotificationKind, ProgramEvent, RRGDBStopSignal, RRTicks, RegisterEventsArg, RunTracepointsArg,
    SourceCallJumpTarget, SourceLocation, StepArg, Stop, StopType, Task, TraceUpdate, TracepointId, TracepointResults,
    UpdateTableArgs, Variable, NO_INDEX, NO_PATH, NO_POSITION, NO_STEP_ID,
};
use crate::tracepoint_interpreter::TracepointInterpreter;

const TRACEPOINT_RESULTS_LIMIT_BEFORE_UPDATE: usize = 5;

#[derive(Debug)]
pub struct Handler {
    pub db: Box<Db>,
    pub step_id: StepId,
    pub last_call_key: CallKey,
    // pub sender_tx: mpsc::Sender<Response>,
    pub indirect_send: bool,
    // pub sender: sender::Sender,
    pub event_db: EventDb,
    pub flow_preloader: FlowPreloader,
    pub expr_loader: ExprLoader,
    pub calltrace: Calltrace,
    pub step_lines_loader: StepLinesLoader,
    pub trace: CoreTrace,
    pub dap_client: DapClient,
    pub resulting_dap_messages: Vec<DapMessage>,
    pub raw_diff_index: Option<String>,
    pub previous_step_id: StepId,
    pub breakpoints: HashMap<(String, i64), Vec<Breakpoint>>,

    pub trace_kind: TraceKind,
    pub replay: Box<dyn Replay>,
    pub ct_rr_args: CtRRArgs,
    pub load_flow_index: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TraceKind {
    DB,
    RR,
}

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
    pub fn new(trace_kind: TraceKind, ct_rr_args: CtRRArgs, db: Box<Db>) -> Handler {
        Self::construct(trace_kind, ct_rr_args, db, false)
    }

    pub fn construct(trace_kind: TraceKind, ct_rr_args: CtRRArgs, db: Box<Db>, indirect_send: bool) -> Handler {
        let calltrace = Calltrace::new(&db);
        let trace = CoreTrace::default();
        let mut expr_loader = ExprLoader::new(trace.clone());
        let step_lines_loader = StepLinesLoader::new(&db, &mut expr_loader);
        let replay: Box<dyn Replay> = if trace_kind == TraceKind::DB {
            Box::new(DbReplay::new(db.clone()))
        } else {
            Box::new(RRDispatcher::new("stable", 0, ct_rr_args.clone()))
        };
        // let sender = sender::Sender::new();
        Handler {
            trace_kind,
            db: db.clone(),
            step_id: StepId(0),
            last_call_key: CallKey(0),
            indirect_send,
            // sender,
            event_db: EventDb::new(),
            flow_preloader: FlowPreloader::new(),
            expr_loader,
            trace,
            calltrace,
            step_lines_loader,
            dap_client: DapClient::default(),
            previous_step_id: StepId(0),
            breakpoints: HashMap::new(),
            replay,
            ct_rr_args,
            load_flow_index: 0,
            resulting_dap_messages: vec![],
            raw_diff_index: None,
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

    // pub fn configure(&mut self, arg: ConfigureArg, task: Task) -> Result<(), Box<dyn Error>> {
    //     self.trace = arg.trace.clone();
    //     self.expr_loader.trace = arg.trace.clone();
    //     self.flow_preloader.expr_loader.trace = arg.trace;
    //     self.return_void(task)?;
    //     Ok(())
    // }

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

    pub fn reset_dap(&mut self) {
        self.resulting_dap_messages = vec![];
    }

    fn send_dap(&mut self, dap_message: &DapMessage) -> Result<(), Box<dyn Error>> {
        self.resulting_dap_messages.push(dap_message.clone());
        Ok(())
    }

    fn respond_dap<T: Serialize>(&mut self, request: dap::Request, value: T) -> Result<(), Box<dyn Error>> {
        let response = DapMessage::Response(dap::Response {
            base: dap::ProtocolMessage {
                seq: self.dap_client.seq,
                type_: "response".to_string(),
            },
            request_seq: request.base.seq,
            success: true,
            command: request.command.clone(),
            message: None,
            body: serde_json::to_value(value)?,
        });
        self.dap_client.seq += 1;
        self.send_dap(&response)
    }

    // will be sent after completion of query
    fn prepare_stopped_event(&mut self, is_main: bool) -> Result<(), Box<dyn Error>> {
        let reason = if is_main { "entry" } else { "step" };
        info!("generate stopped event");
        let raw_event = self.dap_client.stopped_event(reason)?;
        info!("raw stopped event: {:?}", raw_event);
        self.send_dap(&raw_event)?;
        Ok(())
    }

    fn prepare_complete_move_event(&mut self, move_state: &MoveState) -> Result<(), Box<dyn Error>> {
        let raw_complete_move_event = self.dap_client.complete_move_event(move_state)?;
        self.send_dap(&raw_complete_move_event)?;
        Ok(())
    }

    fn prepare_output_events(&mut self) -> Result<(), Box<dyn Error>> {
        if self.trace_kind == TraceKind::RR {
            warn!("prepare_output_events not implemented for rr");
            return Ok(()); // TODO
        }

        if self.step_id.0 > self.previous_step_id.0 {
            let mut raw_output_events: Vec<dap::DapMessage> = vec![];
            for event in self.db.events.iter() {
                if event.step_id.0 > self.previous_step_id.0 && event.step_id.0 <= self.step_id.0 {
                    // different kind of if-s:
                    //   upper if the event is in the range of the move
                    //   this internal one: for which kinds do we produce dap events
                    #[allow(clippy::collapsible_if)]
                    if event.kind == EventLogKind::Write {
                        let step = self.db.steps[event.step_id];
                        info!("generate output event");
                        let raw_output_event = self.dap_client.output_event(
                            "stdout",
                            &self.db.paths[step.path_id],
                            step.line.0 as usize,
                            &event.content,
                        )?;
                        info!("raw output event: {:?}", raw_output_event);
                        raw_output_events.push(raw_output_event);
                    }
                }
            }
            for raw_output_event in raw_output_events.iter() {
                self.send_dap(raw_output_event)?;
            }
        }
        Ok(())
    }

    fn prepare_eventual_error_event(&mut self) -> Result<(), Box<dyn Error>> {
        if self.trace_kind == TraceKind::RR {
            warn!("prepare_eventual_error_event not implemented for rr");
            return Ok(()); // TODO
        }

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

    fn complete_move(&mut self, is_main: bool) -> Result<(), Box<dyn Error>> {
        info!("complete_move");

        // self.db.load_location(self.step_id, call_key, &mut self.expr_loader),
        let location = self.replay.load_location(&mut self.expr_loader)?;
        // let call_key = location.call_key; // self.db.call_key_for_step(self.step_id);
        // TODO: change if we need to support non-int keys
        let call_key = CallKey(location.key.parse::<i64>()?);
        let reset_flow = is_main || call_key != self.last_call_key;
        self.last_call_key = call_key;
        info!("  location: {location:?}");

        let move_state = MoveState {
            status: "".to_string(),
            location,
            c_location: Location::default(),
            main: is_main,
            reset_flow,
            stop_signal: RRGDBStopSignal::OtherStopSignal,
            frame_info: FrameInfo::default(),
        };

        self.prepare_stopped_event(is_main)?;
        self.prepare_complete_move_event(&move_state)?;
        self.prepare_output_events()?;

        self.previous_step_id = self.step_id;

        // self.send_notification(NotificationKind::Success, "Complete move!", true)?;

        self.prepare_eventual_error_event()?;

        Ok(())
    }

    pub fn run_to_entry(&mut self, _req: dap::Request) -> Result<(), Box<dyn Error>> {
        self.replay.run_to_entry()?;
        self.step_id = StepId(0); // TODO: use only db replay step_id or another workaround?
        self.complete_move(true)?;
        Ok(())
    }

    pub fn load_locals(&mut self, req: dap::Request, args: task::CtLoadLocalsArguments) -> Result<(), Box<dyn Error>> {
        // if self.trace_kind == TraceKind::RR {
            // let locals: Vec<Variable> = vec![];
            // warn!("load_locals not implemented for rr yet");
            let locals = self.replay.load_locals(args)?;
            self.respond_dap(req, task::CtLoadLocalsResponseBody { locals })?;
            Ok(())
        // }

        // self.respond_dap(req, task::CtLoadLocalsResponseBody { locals })?;
        // Ok(())
    }

    // pub fn load_callstack(&mut self, task: Task) -> Result<(), Box<dyn Error>> {
    //     let callstack: Vec<Call> = self
    //         .calltrace
    //         .load_callstack(self.step_id, &self.db)
    //         .iter()
    //         .map(|call_record| {
    //             // expanded children count not relevant in raw callstack
    //             self.db.to_call(call_record, &mut self.expr_loader)
    //         })
    //         .collect();

    //     // info!("callstack {:#?}", callstack);
    //     Ok(())
    // }

    pub fn collapse_calls(
        &mut self,
        _req: dap::Request,
        collapse_calls_args: CollapseCallsArgs,
    ) -> Result<(), Box<dyn Error>> {
        if let Ok(num_key) = collapse_calls_args.call_key.clone().parse::<i64>() {
            self.calltrace.change_expand_state(CallKey(num_key), false);
        } else {
            error!("invalid i64 number for call key: {}", collapse_calls_args.call_key);
        }

        // self.return_task((task, VOID_RESULT.to_string()))?;
        Ok(())
    }

    pub fn expand_calls(
        &mut self,
        _req: dap::Request,
        collapse_calls_args: CollapseCallsArgs,
    ) -> Result<(), Box<dyn Error>> {
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
        // self.return_task((task, VOID_RESULT.to_string()))?;
        Ok(())
    }

    fn load_local_calltrace(&mut self, args: CalltraceLoadArgs) -> Result<Vec<CallLine>, Box<dyn Error>> {
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

    pub fn load_calltrace_section(
        &mut self,
        _req: dap::Request,
        args: CalltraceLoadArgs,
    ) -> Result<(), Box<dyn Error>> {
        if self.trace_kind == TraceKind::RR {
            warn!("load_calltrace_section not implemented for rr");
            return Ok(());
        }

        let start_call_line_index = args.start_call_line_index;
        let call_lines = self.load_local_calltrace(args)?;
        let total_count = self.calc_total_calls();
        let position = self.calltrace.calc_scroll_position();
        let update = CallArgsUpdateResults::finished_update_call_lines(
            call_lines,
            start_call_line_index,
            total_count,
            position,
            self.calltrace.depth_offset,
        );
        // self.return_task((task, VOID_RESULT.to_string()))?;
        let raw_event = self.dap_client.updated_calltrace_event(&update)?;
        self.send_dap(&raw_event)?;
        Ok(())
    }

    pub fn load_flow(&mut self, _req: dap::Request, arg: CtLoadFlowArguments) -> Result<(), Box<dyn Error>> {
        let mut flow_replay: Box<dyn Replay> = if self.trace_kind == TraceKind::DB {
            Box::new(DbReplay::new(self.db.clone()))
        } else {
            Box::new(RRDispatcher::new("flow", self.load_flow_index, self.ct_rr_args.clone()))
        };
        self.load_flow_index += 1;

        // TODO: eventually cleanup or manage in a more optimal way flow replays: caching
        // if possible for example

        let flow_update = if arg.flow_mode == FlowMode::Call {
            self.flow_preloader.load(arg.location, arg.flow_mode, &mut *flow_replay)
        } else {
            if let Some(raw_flow) = &self.raw_diff_index {
                serde_json::from_str::<FlowUpdate>(&raw_flow)?
            } else {
                // TODO: notification? or ignore
                // eventually in the future: make a diff index now in the replay and send it
                let message = "no raw diff index in handler, can't send flow for diff for now";
                warn!("{}", message);
                return Err(message.into());
            }
        };
        let raw_event = self.dap_client.updated_flow_event(flow_update)?;

        self.send_dap(&raw_event)?;

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

    pub fn step_in(&mut self, forward: bool) -> Result<(), Box<dyn Error>> {
        self.replay.step(Action::StepIn, forward)?;
        self.step_id = self.replay.current_step_id();

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

    pub fn next(&mut self, forward: bool) -> Result<(), Box<dyn Error>> {
        self.replay.step(Action::Next, forward)?;
        self.step_id = self.replay.current_step_id();
        Ok(())
    }

    pub fn step_out(&mut self, forward: bool) -> Result<(), Box<dyn Error>> {
        self.replay.step(Action::StepOut, forward)?;
        self.step_id = self.replay.current_step_id();
        Ok(())
    }

    #[allow(clippy::expect_used)]
    pub fn step_continue(&mut self, forward: bool) -> Result<(), Box<dyn Error>> {
        if !self.replay.step(Action::Continue, forward)? {
            self.send_notification(NotificationKind::Info, "No breakpoints were hit!", false)?;
        }
        self.step_id = self.replay.current_step_id();
        Ok(())
    }

    pub fn step(&mut self, request: dap::Request, arg: StepArg) -> Result<(), Box<dyn Error>> {
        // for now not supporting repeat/skip_internal: TODO
        // TODO: reverse
        let original_step_id = self.step_id;
        // let original_step = self.db.steps[original_step_id];
        // let original_depth = self.db.calls[original_step.call_key].depth;
        match arg.action {
            Action::StepIn => self.step_in(!arg.reverse)?,
            Action::Next => self.next(!arg.reverse)?,
            Action::StepOut => self.step_out(!arg.reverse)?,
            Action::Continue => self.step_continue(!arg.reverse)?,
            _ => error!("action {:?} not implemented", arg.action),
        }
        if arg.complete { // && arg.action != Action::Continue {
            self.complete_move(false)?;
        }

        if self.trace_kind == TraceKind::DB {
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

        self.respond_dap(request, 0)?;
        Ok(())
    }

    pub fn event_load(&mut self, _req: dap::Request) -> Result<(), Box<dyn Error>> {
        let events_data = self.replay.load_events()?;

        let events = events_data.events;
        let first_events = events_data.first_events;
        let contents = events_data.contents;

        self.event_db.register_events(DbEventKind::Record, &events, vec![-1]);
        self.event_db.refresh_global();

        let raw_event = self.dap_client.updated_events(first_events)?;
        self.send_dap(&raw_event)?;

        let raw_event_content = self.dap_client.updated_events_content(contents)?;
        self.send_dap(&raw_event_content)?;

        Ok(())
    }

    pub fn event_jump(&mut self, _req: dap::Request, event: ProgramEvent) -> Result<(), Box<dyn Error>> {
        let step_id = StepId(event.direct_location_rr_ticks); // currently using this field
                                                              // for compat with rr/gdb core support
        self.replay.jump_to(step_id)?;
        self.step_id = self.replay.current_step_id();
        self.complete_move(false)?;

        Ok(())
    }

    pub fn calltrace_jump(&mut self, _req: dap::Request, location: Location) -> Result<(), Box<dyn Error>> {
        let step_id = StepId(location.rr_ticks.0); // using this field
                                                   // for compat with rr/gdb core support
        self.replay.jump_to(step_id)?;
        self.step_id = self.replay.current_step_id();
        self.complete_move(false)?;

        Ok(())
    }

    pub fn calltrace_search(&mut self, _req: dap::Request, arg: CallSearchArg) -> Result<(), Box<dyn Error>> {
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

        let raw_event = self.dap_client.calltrace_search_event(calls)?;
        self.send_dap(&raw_event)?;
        Ok(())
    }

    fn id_to_name(&self, variable_id: VariableId) -> &String {
        &self.db.variable_names[variable_id]
    }

    pub fn load_history(&mut self, _req: dap::Request, load_history_arg: LoadHistoryArg) -> Result<(), Box<dyn Error>> {
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
        let raw_event = self.dap_client.updated_history_event(history_update)?;

        self.send_dap(&raw_event)?;
        // self.send_event((
        //     EventKind::UpdatedHistory,
        //     gen_event_id(EventKind::UpdatedHistory),
        //     serde_json::to_string(&history_update)?,
        //     false,
        // ))?;

        Ok(())
    }

    pub fn history_jump(&mut self, _req: dap::Request, loc: Location) -> Result<(), Box<dyn Error>> {
        self.replay.jump_to(StepId(loc.rr_ticks.0))?;
        self.step_id = self.replay.current_step_id();
        self.complete_move(false)?;
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

    pub fn source_line_jump(
        &mut self,
        _req: dap::Request,
        source_location: SourceLocation,
    ) -> Result<(), Box<dyn Error>> {
        if self.trace_kind == TraceKind::DB {
            if let Some(step_id) = self.get_closest_step_id(&source_location) {
                self.replay.jump_to(step_id)?;
                self.step_id = self.replay.current_step_id();
                self.complete_move(false)?;
                Ok(())
            } else {
                let err: String = format!("unknown location: {}", &source_location);
                Err(err.into())
            }
        } else {
            let b = self.replay.add_breakpoint(&source_location.path, source_location.line as i64)?;
            match self.replay.step(Action::Continue, true) {
                Ok(_) => {
                    self.replay.delete_breakpoint(&b)?; // make sure we do it before potential `?` fail in next functions
                    let _location = self.replay.load_location(&mut self.expr_loader)?;
                    self.step_id = self.replay.current_step_id();
                    self.complete_move(false)?;
                    Ok(())
                }
                Err(e) => {
                    self.replay.delete_breakpoint(&b)?;
                    Err(e)
                }
            }
        }
    }

    // fn step_id_jump(&mut self, step_id: StepId) {
    //     if step_id.0 != NO_INDEX {
    //         self.step_id = step_id;
    //     }
    // }

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

    pub fn source_call_jump(
        &mut self,
        _req: dap::Request,
        call_target: SourceCallJumpTarget,
    ) -> Result<(), Box<dyn Error>> {
        if let Some(line_step_id) = self.get_closest_step_id(&SourceLocation {
            line: call_target.line,
            path: call_target.path.clone(),
        }) {
            self.replay.jump_to(line_step_id)?;
            self.step_id = self.replay.current_step_id();
        }

        if let Some(call_step_id) = self.get_call_target(&call_target) {
            self.replay.jump_to(call_step_id)?;
            self.step_id = self.replay.current_step_id();
            self.complete_move(false)?;
            Ok(())
        } else {
            let err: String = format!("unknown call location: {}", &call_target);
            self.complete_move(false)?;
            self.send_notification(
                NotificationKind::Error,
                "Line reached but couldn't find the function!",
                false,
            )?;
            Err(err.into())
        }
    }

    pub fn set_breakpoints(&mut self, request: dap::Request, args: dap_types::SetBreakpointsArguments) -> Result<(), Box<dyn Error>> {
        let mut results = Vec::new();
        // for now simples to redo them every time: TODO possible optimizations
        self.clear_breakpoints()?;
        if let Some(path) = args.source.path.clone() {
            let lines: Vec<i64> = if let Some(bps) = args.breakpoints {
                bps.into_iter().map(|b| b.line).collect()
            } else {
                args.lines.unwrap_or_default()
            };
        
            for line in lines {
                let _ = self.add_breakpoint(
                    SourceLocation {
                        path: path.clone(),
                        line: line as usize,
                    },
                );
                results.push(dap_types::Breakpoint {
                    id: None,
                    verified: true,
                    message: None,
                    source: Some(dap_types::Source {
                        name: args.source.name.clone(),
                        path: Some(path.clone()),
                        source_reference: args.source.source_reference,
                        presentation_hint: None,
                        origin: None,
                        sources: None,
                        adapter_data: None,
                        checksums: None,
                    }),
                    line: Some(line),
                    column: None,
                    end_line: None,
                    end_column: None,
                    instruction_reference: None,
                    offset: None,
                    reason: None,
                });
            }
        } else {
            let lines = args
                .breakpoints
                .unwrap_or_default()
                .into_iter()
                .map(|b| b.line)
                .collect::<Vec<_>>();
            for line in lines {
                results.push(dap_types::Breakpoint {
                    id: None,
                    verified: false,
                    message: Some("missing source path".to_string()),
                    source: None,
                    line: Some(line),
                    column: None,
                    end_line: None,
                    end_column: None,
                    instruction_reference: None,
                    offset: None,
                    reason: None,
                });
            }
        }
        self.respond_dap(request, dap_types::SetBreakpointsResponseBody { breakpoints: results })?;
        Ok(())
    }

    pub fn add_breakpoint(&mut self, loc: SourceLocation) -> Result<(), Box<dyn Error>> {
       let breakpoint = self.replay.add_breakpoint(&loc.path, loc.line as i64)?;
       let entry = self.breakpoints.entry((loc.path.clone(), loc.line as i64)).or_default();
       entry.push(breakpoint);
       Ok(())
    }

    pub fn delete_breakpoints_for_location(&mut self, loc: SourceLocation, _task: Task) -> Result<(), Box<dyn Error>> {
        if self.breakpoints.contains_key(&(loc.path.clone(), loc.line as i64)) {
            for breakpoint in &self.breakpoints[&(loc.path.clone(), loc.line as i64)] {
                self.replay.delete_breakpoint(breakpoint)?;
            }
        }
        Ok(())
    }

    pub fn clear_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        let _ = self.replay.delete_breakpoints()?;
        self.breakpoints.clear();
        Ok(())
    }

    pub fn toggle_breakpoint(&mut self, _loc: SourceLocation, _task: Task) -> Result<(), Box<dyn Error>> {
        // TODO: use path,line to id map: self.replay.toggle_breakpoint()?;
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

    pub fn run_tracepoints(&mut self, req: dap::Request, args: RunTracepointsArg) -> Result<(), Box<dyn Error>> {
        // Sort steps in StepId Ord
        self.setup_trace_session(req, args.clone())?;

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
            let raw_event = self.dap_client.updated_trace_event(trace_update)?;
            self.send_dap(&raw_event)?;
        }
        Ok(())
    }

    pub fn trace_jump(&mut self, _req: dap::Request, event: ProgramEvent) -> Result<(), Box<dyn Error>> {
        self.replay.jump_to(StepId(event.direct_location_rr_ticks))?;
        self.step_id = self.replay.current_step_id();
        self.complete_move(false)?;
        Ok(())
    }

    pub fn tracepoint_delete(&mut self, _req: dap::Request, tracepoint_id: TracepointId) -> Result<(), Box<dyn Error>> {
        self.event_db.clear_single_table(SingleTableId(tracepoint_id.id + 1));
        self.event_db.refresh_global();
        let mut t_update = TraceUpdate::new(0, false, tracepoint_id.id, self.event_db.tracepoint_errors.clone());
        t_update.refresh_event_log = true;
        let raw_event = self.dap_client.updated_trace_event(t_update)?;
        self.send_dap(&raw_event)?;
        Ok(())
    }

    pub fn tracepoint_toggle(&mut self, _req: dap::Request, tracepoint_id: TracepointId) -> Result<(), Box<dyn Error>> {
        let table_id = self.event_db.make_single_table_id(tracepoint_id.id);
        if self.event_db.disabled_tables.contains(&table_id) {
            self.event_db.enable_table(table_id);
        } else {
            self.event_db.disable_table(table_id);
        }
        self.event_db.refresh_global();
        let mut t_update = TraceUpdate::new(0, false, tracepoint_id.id, self.event_db.tracepoint_errors.clone());
        t_update.refresh_event_log = true;
        let raw_event = self.dap_client.updated_trace_event(t_update)?;
        self.send_dap(&raw_event)?;
        Ok(())
    }

    pub fn search_program(&mut self, query: String, _task: Task) -> Result<(), Box<dyn Error>> {
        let program_search_tool = ProgramSearchTool::new(&self.db);
        let _results = program_search_tool.search(&query, &mut self.expr_loader)?;
        // TODO: send with DAP
        // self.send_event((
        //     EventKind::ProgramSearchResults,
        //     gen_event_id(EventKind::ProgramSearchResults),
        //     self.serialize(&results)?,
        //     false,
        // ))?;
        // self.return_void(task)?;
        Ok(())
    }

    pub fn load_step_lines(&mut self, arg: LoadStepLinesArg, _task: Task) -> Result<(), Box<dyn Error>> {
        let step_lines = vec![];
        // self.step_lines_loader.load_lines(
        //     &arg.location,
        //     arg.backward_count,
        //     arg.forward_count,
        //     &self.db,
        //     &mut self.flow_preloader,
        // );
        let _step_lines_update = LoadStepLinesUpdate {
            results: step_lines,
            arg_location: arg.location,
            finish: true,
        };
        // TODO: send with DAP
        // self.send_event((
        //     EventKind::UpdatedLoadStepLines,
        //     gen_event_id(EventKind::UpdatedLoadStepLines),
        //     self.serialize(&step_lines_update)?,
        //     false,
        // ))?;
        // self.return_void(task)?;
        Ok(())
    }

    pub fn local_step_jump(&mut self, _req: dap::Request, arg: LocalStepJump) -> Result<(), Box<dyn Error>> {
        self.replay.jump_to(StepId(arg.rr_ticks))?;
        self.step_id = self.replay.current_step_id();
        self.complete_move(false)?;
        Ok(())
    }

    pub fn register_events(&mut self, arg: RegisterEventsArg, _task: Task) -> Result<(), Box<dyn Error>> {
        self.event_db.register_events(arg.kind, &arg.events, vec![-1]);
        self.event_db.refresh_global();
        // TODO: rr-backend virtualization layers support self.return_void(task)?;
        Ok(())
    }

    pub fn setup_trace_session(&mut self, _req: dap::Request, arg: RunTracepointsArg) -> Result<(), Box<dyn Error>> {
        for trace in arg.session.tracepoints {
            while trace.tracepoint_id + 1 >= self.event_db.single_tables.len() {
                self.event_db.add_new_table(DbEventKind::Trace, &[]);
            }
            assert!(self.event_db.single_tables.len() > trace.tracepoint_id + 1);
        }
        Ok(())
    }

    pub fn register_tracepoint_logs(&mut self, arg: TracepointResults, _task: Task) -> Result<(), Box<dyn Error>> {
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
        // TODO: send with DAP for virtualization layers
        // self.send_event((
        //     EventKind::UpdatedTrace,
        //     gen_event_id(EventKind::UpdatedTrace),
        //     self.serialize(&trace_update)?,
        //     false,
        // ))?;
        // self.return_void(task)?;
        Ok(())
    }

    pub fn update_table(&mut self, _req: dap::Request, args: UpdateTableArgs) -> Result<(), Box<dyn Error>> {
        let (table_update, _trace_values_option) = self.event_db.update_table(args)?;
        // TODO: For now no trace values are available
        // if let Some(trace_values) = trace_values_option {
        //     self.send_event((
        //         EventKind::TracepointLocals,
        //         gen_event_id(EventKind::TracepointLocals),
        //         self.serialize(&trace_values)?,
        //         false,
        //     ))?;
        // }
        // info!("table update {:?}", table_update);
        let raw_event = self
            .dap_client
            .updated_table_event(&task::CtUpdatedTableResponseBody { table_update })?;
        self.send_dap(&raw_event)?;
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
                            list.insert(line, step.step_id);
                        } else if step.step_id >= self.step_id {
                            list.entry(line)
                                .and_modify(|e| *e = step.step_id)
                                .or_insert(step.step_id);
                            // We change the line entry and break because we have found the next closest
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

    pub fn load_asm_function(&mut self, request: dap::Request, args: FunctionLocation) -> Result<(), Box<dyn Error>> {
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
                self.respond_dap(request, instructions)?;
                Ok(())
            }
            Err(e) => Err(Box::new(e)),
        }
    }

    pub fn load_terminal(&mut self, _req: dap::Request) -> Result<(), Box<dyn Error>> {
        let mut events_list: Vec<ProgramEvent> = vec![];
        for (i, event_record) in self.db.events.iter().enumerate() {
            if event_record.kind == EventLogKind::Write {
                events_list.push(self.to_program_event(event_record, i));
            }
        }

        let raw_event = self.dap_client.loaded_terminal_event(events_list)?;
        self.send_dap(&raw_event)?;

        Ok(())
    }

    fn send_notification(
        &mut self,
        kind: NotificationKind,
        msg: &str,
        is_operation_status: bool,
    ) -> Result<(), Box<dyn Error>> {
        let notification = Notification::new(kind, msg, is_operation_status);
        let raw_event = self.dap_client.notification_event(notification)?;
        self.send_dap(&raw_event)?;
        Ok(())
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

    fn serialize<T: Serialize>(&self, value: &T) -> Result<String, Box<dyn Error>> {
        let res = serde_json::to_string(value)?;
        Ok(res)
    }

    pub fn produce_stack_frame(&mut self, call_record: &DbCall) -> dap_types::StackFrame {
        // for this simplified scenario:
        // step 1: call 1
        // step 2: call 1
        // step 3: call 2
        // step 4: call 2
        // we were returning the function-entry locations: equivalent of steps [3, 1]
        // now with a workaround, we return the correct current frame(call) step(location), but keep
        //   returning the function-entry locations for upper frames(calls), so with DAP
        //   we can at least return the correct current location
        //   the equivalent of [4, 1]
        // eventually: TODO: return the current upper frame location/steps as well:
        //   the equivalent of [4, 2]
        //   how to do it efficiently is a non-trivial question: maybe by iterating through previous steps,
        //   or a new kind of index?
        let call = self.db.to_call(call_record, &mut self.expr_loader);
        let location = if call_record.key == self.db.steps[self.step_id].call_key {
            self.db
                .load_location(self.step_id, call_record.key, &mut self.expr_loader)
        } else {
            call.location
        };
        dap_types::StackFrame {
            id: call_record.key.0,
            name: location.function_name,
            source: Some(dap_types::Source {
                name: Some("".to_string()),
                path: Some(location.path),
                source_reference: None,
                adapter_data: None,
                checksums: None,
                origin: None,
                presentation_hint: None,
                sources: None,
            }),
            line: if location.line >= 0 { location.line } else { 0 },
            column: 1,
            end_line: None,
            end_column: None,
            instruction_pointer_reference: None,
            module_id: None,
            presentation_hint: None,
            can_restart: None,
        }
    }
    pub fn threads(&mut self, request: dap::Request) -> Result<(), Box<dyn Error>> {
        self.respond_dap(
            request,
            dap_types::ThreadsResponseBody {
                threads: vec![dap_types::Thread {
                    id: 1,
                    name: "<thread 1>".to_string(),
                }],
            },
        )?;
        Ok(())
    }

    pub fn stack_trace(
        &mut self,
        request: dap::Request,
        args: dap_types::StackTraceArguments,
    ) -> Result<(), Box<dyn Error>> {
        let stack_frames: Vec<dap_types::StackFrame> = if args.thread_id == 1 {
            self.calltrace
                .load_callstack(self.step_id, &self.db)
                .iter()
                .map(|call_record| {
                    // expanded children count not relevant in raw callstack
                    self.produce_stack_frame(call_record)
                })
                .collect()
        } else {
            vec![]
        };
        let total_frames = Some(stack_frames.len() as i64);
        self.respond_dap(
            request,
            dap_types::StackTraceResponseBody {
                stack_frames,
                total_frames,
            },
        )?;
        Ok(())
    }

    pub fn scopes(&mut self, request: dap::Request, arg: dap_types::ScopesArguments) -> Result<(), Box<dyn Error>> {
        let call = &self.db.calls[CallKey(arg.frame_id)];
        let function = &self.db.functions[call.function_id];
        let scope = dap_types::Scope {
            name: function.name.clone(),
            presentation_hint: Some("locals".to_string()),
            variables_reference: arg.frame_id,
            named_variables: Some(0),
            indexed_variables: Some(0),
            expensive: false,
            source: None,
            line: Some(function.line.0),
            column: Some(1),
            end_line: None,
            end_column: None,
        };
        self.respond_dap(request, dap_types::ScopesResponseBody { scopes: vec![scope] })?;

        Ok(())
    }

    pub fn to_dap_variable(&self, ct_variable: &Variable) -> dap_types::Variable {
        let dap_value_text = ct_variable.value.text_repr();
        dap::new_dap_variable(&ct_variable.expression, &dap_value_text, 0)
    }

    pub fn variables(
        &mut self,
        request: dap::Request,
        _arg: dap_types::VariablesArguments,
    ) -> Result<(), Box<dyn Error>> {
        let full_value_locals: Vec<Variable> = self.db.variables[self.step_id]
            .iter()
            .map(|v| Variable {
                expression: self.db.variable_name(v.variable_id).to_string(),
                value: self.db.to_ct_value(&v.value),
            })
            .collect();

        let dap_variables = full_value_locals.iter().map(|v| self.to_dap_variable(v)).collect();

        self.respond_dap(
            request,
            dap_types::VariablesResponseBody {
                variables: dap_variables,
            },
        )?;

        Ok(())
    }

    pub fn respond_to_disconnect(
        &mut self,
        request: dap::Request,
        _arg: dap_types::DisconnectArguments,
    ) -> Result<(), Box<dyn Error>> {
        self.respond_dap(request, dap::DisconnectResponseBody {})?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::env;
    use std::path::{Path, PathBuf};

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
        CallRecord, FieldTypeRecord, FunctionId, FunctionRecord, NonStreamingTraceWriter, StepId, StepRecord,
        TraceLowLevelEvent, TraceMetadata, TraceWriter, TypeId, TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord,
        NONE_VALUE,
    };

    use task::{TaskKind, TraceSession, Tracepoint, TracepointMode};

    #[test]
    fn test_struct_handling() {
        let db = setup_db();
        let handler: Handler = Handler::new(TraceKind::DB, CtRRArgs::default(), Box::new(db));
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

        // Act: Create a new Handler instance
        let handler: Handler = Handler::new(TraceKind::DB, CtRRArgs::default(), Box::new(db));

        // Assert: Check that the Handler instance is correctly initialized
        assert_eq!(handler.step_id, StepId(0));
        assert!(!handler.breakpoint_list.is_empty());
    }

    // Test single tracepoint
    #[test]
    fn test_run_single_tracepoint() -> Result<(), Box<dyn Error>> {
        let db = setup_db();
        let mut handler: Handler = Handler::new(TraceKind::DB, CtRRArgs::default(), Box::new(db));
        handler.event_load(dap::Request::default())?;
        handler.run_tracepoints(dap::Request::default(), make_tracepoints_args(1, 0))?;
        assert_eq!(handler.event_db.single_tables.len(), 2);
        Ok(())
    }

    // Test basic multiple tracepoints
    #[test]
    fn test_multiple_tracepoints() -> Result<(), Box<dyn Error>> {
        let db = setup_db();
        let mut handler: Handler = Handler::new(TraceKind::DB, CtRRArgs::default(), Box::new(db));
        handler.event_load(dap::Request::default())?;
        // TODO
        // this way we are resetting them after reforms
        // needs to pass multiple tracepoints at once now
        // handler.run_tracepoints(
        //     dap::Request::default(),
        //     make_tracepoints_args(3, 0),
        // )?;
        // handler.run_tracepoints(
        //     dap::Request::default(),
        //     make_tracepoints_args(2, 1),
        // )?;
        // handler.run_tracepoints(
        //     dap::Request::default(),
        //     make_tracepoints_args(1, 2),
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
        let mut handler: Handler = Handler::new(TraceKind::DB, CtRRArgs::default(), Box::new(db));
        handler.event_load(dap::Request::default())?;
        handler.run_tracepoints(
            dap::Request::default(),
            make_multiple_tracepoints_with_multiline_logs(3, size),
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
        let mut handler: Handler = Handler::new(TraceKind::DB, CtRRArgs::default(), Box::new(db));
        handler.event_load(dap::Request::default())?;
        handler.run_tracepoints(dap::Request::default(), make_tracepoints_args(2, 0))?;
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
        let mut handler: Handler = Handler::new(TraceKind::DB, CtRRArgs::default(), Box::new(db));
        handler.event_load(dap::Request::default())?;
        handler.run_tracepoints(dap::Request::default(), make_tracepoints_with_count(count))?;

        assert_eq!(handler.event_db.single_tables.len(), count + 1);
        Ok(())
    }

    #[test]
    fn test_step_in() -> Result<(), Box<dyn Error>> {
        let db = setup_db();

        // Act: Create a new Handler instance
        let mut handler: Handler = Handler::new(TraceKind::DB, CtRRArgs::default(), Box::new(db));
        let request = dap::Request::default();
        handler.step(request, make_step_in())?;
        assert_eq!(handler.step_id, StepId(1_i64));
        Ok(())
    }

    #[test]
    fn test_source_jumps() -> Result<(), Box<dyn Error>> {
        let db = setup_db();
        let mut handler: Handler = Handler::new(TraceKind::DB, CtRRArgs::default(), Box::new(db));
        let path = "/test/workdir";
        let source_location: SourceLocation = SourceLocation {
            path: path.to_string(),
            line: 3,
        };
        handler.source_line_jump(dap::Request::default(), source_location)?;
        assert_eq!(handler.step_id, StepId(2));
        handler.source_line_jump(
            dap::Request::default(),
            SourceLocation {
                path: path.to_string(),
                line: 2,
            },
        )?;
        assert_eq!(handler.step_id, StepId(1));
        handler.source_call_jump(
            dap::Request::default(),
            SourceCallJumpTarget {
                path: "/test/workdir".to_string(),
                line: 1,
                token: "<top-level>".to_string(),
            },
        )?;
        assert_eq!(handler.step_id, StepId(0));
        Ok(())
    }

    #[test]
    fn test_local_calltrace() -> Result<(), Box<dyn Error>> {
        let db = setup_db_with_calls();
        let mut handler: Handler = Handler::new(TraceKind::DB, CtRRArgs::default(), Box::new(db));

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
            render_call_line_index: 0,
        };
        let _call_lines = handler.load_local_calltrace(calltrace_load_args)?;

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
        let mut handler: Handler = Handler::new(TraceKind::DB, CtRRArgs::default(), Box::new(db));

        // step-in from 1 to end(maybe also a parameter?)
        // on each step check validity, load locals, load callstack
        // eventually: loading local calltrace? or at least for first real call?
        // eventually: loading flow for new calls?
        // first version loading locals/callstack
        test_step_in_scenario(&mut handler, path);
    }

    fn test_load_flow(handler: &mut Handler, _path: &PathBuf) {
        handler
            .load_flow(
                dap::Request::default(),
                CtLoadFlowArguments {
                    flow_mode: FlowMode::Call,
                    location: handler.load_location(handler.step_id)
                })
            .unwrap();
    }

    fn test_step_in_scenario(handler: &mut Handler, path: &PathBuf) {
        for i in 0..handler.db.steps.len() - 1 {
            // eprintln!("doing step-in {i}");
            handler.step_in(true).unwrap();
            assert_eq!(handler.step_id, StepId(i as i64 + 1));
            test_load_locals(handler);
            // test_load_callstack(handler);
            test_load_flow(handler, path);
        }
    }

    fn test_load_locals(handler: &mut Handler) {
        handler
            .load_locals(dap::Request::default(), task::CtLoadLocalsArguments::default())
            .unwrap();
    }

    // fn test_load_callstack(handler: &mut Handler) {
    //     handler.load_callstack(gen_task(TaskKind::LoadCallstack)).unwrap();
    // }

    fn gen_task(kind: TaskKind) -> Task {
        Task {
            kind,
            id: gen_task_id(kind),
        }
    }
    fn load_db_for_trace(path: &Path) -> Db {
        let mut trace_file = path.join("trace.bin");
        let mut trace_file_format = runtime_tracing::TraceEventsFileFormat::Binary;
        if !trace_file.exists() {
            trace_file = path.join("trace.json");
            trace_file_format = runtime_tracing::TraceEventsFileFormat::Json;
        }
        let trace_metadata_file = path.join("trace_metadata.json");
        let trace = load_trace_data(&trace_file, trace_file_format).expect("expected that it can load the trace file");
        info!("trace {:?}", trace);
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
        let mut tracer = NonStreamingTraceWriter::new("example.small", &[]);
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
