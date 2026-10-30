//! A move that fails part-way leaves the user's breakpoints as they were,
//! and reports where it left the replay.
//!
//! Spec reference: codetracer-specs
//! `spec/Architecture/CodeTracer-DAP-Extensions.md`, "Every request is
//! answered, including one whose handler panics": when the handler returns an
//! error, "a handler that returns an error is expected to leave its session
//! consistent".
//!
//! ## What this pins
//!
//! On a replay that is not materialized, `ct/local-step-jump` and
//! `ct/source-line-jump` move inside a *run-to-line bracket*: they suppress
//! the user's breakpoints (`disable_breakpoints`), set one temporary
//! breakpoint on the target line, `Continue` until it is hit, then delete the
//! temporary breakpoint and lift the suppression (`enable_breakpoints`). Each
//! case below makes one step of that sequence fail and checks that, once the
//! request has returned its error, the suppression is lifted and no
//! temporary breakpoint is left behind. Before the fix every step ended in
//! `?`, so a failure after `disable_breakpoints` returned with the user's
//! breakpoints still suppressed: the session went on, and never stopped at
//! them again.
//!
//! The same requests, and a step that goes on past an internal JIT
//! registration stop, make several moves in a row. When one of them fails
//! after others have run, the replay is wherever the last successful move
//! stopped. The request is still answered `success: false` with the error,
//! but first the handler's step is brought up to date and that stop is
//! reported (`stopped` and `ct/complete-move`), as `ct/source-line-jump`
//! already did when its moves failed. Before that fix these requests
//! returned with the handler's step and the client's view still at the stop
//! before the request, so the next move started from a position the client
//! had never been shown.
//!
//! ## Why a test double stands in for the replay session
//!
//! [`BracketReplay`] replaces the trace's `ReplaySession` and keeps the
//! facts this pins — whether the user's breakpoints are suppressed, which
//! temporary breakpoints are set, and how many moves have succeeded (its
//! position, reported as both the step id and the location's `rr_ticks`) —
//! failing the one call each case names. The production session for these
//! traces is an rr replay driven through the `ct-native-replay` worker from
//! the sibling `codetracer-native-backend` repository. A real worker cannot
//! be made to fail a chosen `Continue` (or a chosen breakpoint operation) on
//! demand, and the defect is entirely in the handler's bookkeeping around
//! those calls, not in the worker. So the double supplies the calls'
//! outcomes and nothing else; every trait method these requests do not use
//! is unreachable and panics if called.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::error::Error;
use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

use codetracer_trace_types::StepId;
use db_backend::dap::{self, DapMessage};
use db_backend::dap_handler::Handler;
use db_backend::db::{Db, DbRecordEvent};
use db_backend::expr_loader::ExprLoader;
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::lang::Lang;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::replay::ReplaySession;
use db_backend::task::{
    Action, Breakpoint, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg,
    LocalStepJump, Location, MoveState, ProgramEvent, RRTicks, SourceLocation, StepArg, TraceKind, VariableWithRecord,
};
use db_backend::value::ValueRecordWithType;
use serde_json::json;

const SOURCE_PATH: &str = "/test/workdir/main.c";

/// Which call of the bracket the double fails.
#[derive(Debug, Clone, Copy)]
enum Failure {
    /// Setting the temporary breakpoint.
    AddBreakpoint,
    /// The `Continue` with this 1-based ordinal.
    Continue(usize),
    /// Deleting the temporary breakpoint.
    DeleteBreakpoint,
}

/// What the double knows about the session's breakpoints.
#[derive(Debug, Default)]
struct BracketState {
    /// `disable_breakpoints` has run and `enable_breakpoints` has not.
    suppressed: bool,
    /// Ids of the temporary breakpoints still set.
    temporaries: Vec<i64>,
    next_id: i64,
    continues: usize,
    /// How many moves (`Continue`s and steps) have succeeded: where the
    /// replay is. A failed move leaves it where it was.
    position: i64,
}

/// A `ReplaySession` that answers the run-to-line bracket only. See the
/// module documentation for why it is a double.
#[derive(Debug)]
struct BracketReplay {
    state: Arc<Mutex<BracketState>>,
    fail: Failure,
    /// The double reports every stop as one inside the JIT debug-symbol
    /// registration hook, which a live session continues past.
    at_jit_registration: bool,
}

const ONLY_THE_BRACKET: &str = "BracketReplay answers the moves of a run-to-line bracket or a step only";

impl ReplaySession for BracketReplay {
    fn disable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        self.state.lock().expect("state").suppressed = true;
        Ok(())
    }
    fn enable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        self.state.lock().expect("state").suppressed = false;
        Ok(())
    }
    fn add_breakpoint(
        &mut self,
        _path: &str,
        _line: i64,
        column: Option<i64>,
        _condition: Option<String>,
    ) -> Result<Breakpoint, Box<dyn Error>> {
        if matches!(self.fail, Failure::AddBreakpoint) {
            return Err("injected: the temporary breakpoint cannot be set".into());
        }
        let mut state = self.state.lock().expect("state");
        state.next_id += 1;
        let id = state.next_id;
        state.temporaries.push(id);
        Ok(Breakpoint {
            id,
            enabled: true,
            column,
            ..Breakpoint::default()
        })
    }
    fn delete_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>> {
        if matches!(self.fail, Failure::DeleteBreakpoint) {
            return Err("injected: the temporary breakpoint cannot be deleted".into());
        }
        self.state
            .lock()
            .expect("state")
            .temporaries
            .retain(|id| *id != breakpoint.id);
        Ok(true)
    }
    fn step(&mut self, action: Action, _forward: bool) -> Result<bool, Box<dyn Error>> {
        assert!(
            matches!(action, Action::Continue | Action::StepIn),
            "these requests only continue and step in"
        );
        let mut state = self.state.lock().expect("state");
        if matches!(action, Action::Continue) {
            state.continues += 1;
            if let Failure::Continue(n) = self.fail
                && state.continues == n
            {
                return Err(format!("injected: continue #{n} failed").into());
            }
        }
        state.position += 1;
        Ok(true)
    }
    fn load_location(&mut self, _expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
        let position = self.state.lock().expect("state").position;
        Ok(Location {
            path: SOURCE_PATH.to_string(),
            line: 1,
            rr_ticks: RRTicks(position),
            function_name: if self.at_jit_registration {
                "__jit_debug_register_code".to_string()
            } else {
                String::new()
            },
            ..Location::default()
        })
    }
    fn current_step_id(&mut self) -> StepId {
        StepId(self.state.lock().expect("state").position)
    }

    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn load_events(&mut self) -> Result<Events, Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn load_locals(&mut self, _arg: CtLoadLocalsArguments) -> Result<Vec<VariableWithRecord>, Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn load_value(
        &mut self,
        _expression: &str,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn load_return_value(
        &mut self,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn load_step_events(&mut self, _step_id: StepId, _exact: bool) -> Vec<DbRecordEvent> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn load_history(&mut self, _arg: &LoadHistoryArg) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn toggle_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn jump_to(&mut self, _step_id: StepId) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn jump_to_call(&mut self, _location: &Location) -> Result<Location, Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn event_jump(&mut self, _event: &ProgramEvent) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn callstack_jump(&mut self, _depth: usize) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn location_jump(&mut self, _location: &Location) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn tracepoint_jump(&mut self, _event: &ProgramEvent) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn evaluate_call_expression(
        &mut self,
        _call_expression: &str,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

/// An rr-kind handler over the double, and the state the double keeps.
fn handler_failing(fail: Failure) -> (Handler, Arc<Mutex<BracketState>>) {
    handler_over(fail, RecreatorArgs::default(), false)
}

/// [`handler_failing`] with the session's arguments and the double's JIT
/// registration stops chosen by the caller.
fn handler_over(fail: Failure, args: RecreatorArgs, at_jit_registration: bool) -> (Handler, Arc<Mutex<BracketState>>) {
    let state = Arc::new(Mutex::new(BracketState::default()));
    let handler = Handler::construct_with_replay(
        TraceKind::Recreator,
        args,
        Arc::new(InMemoryTraceReader::new(Db::new(&PathBuf::from("/test/workdir")))),
        Box::new(BracketReplay {
            state: Arc::clone(&state),
            fail,
            at_jit_registration,
        }),
        false,
    );
    (handler, state)
}

fn request(command: &str) -> dap::Request {
    dap::Request {
        base: dap::ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: command.to_string(),
        arguments: json!({}),
    }
}

/// From line 1 to the third iteration of a loop at line 5: one Continue onto
/// the loop, three across iterations, one onto the target line — five in all.
fn loop_jump() -> LocalStepJump {
    LocalStepJump {
        path: SOURCE_PATH.to_string(),
        line: 6,
        step_count: 0,
        target_iteration: 3,
        first_loop_line: 5,
        rr_ticks: 0,
        reverse: false,
        active_iteration: 0,
    }
}

/// The request failed, and the bracket it opened is closed again.
fn assert_bracket_closed(outcome: Result<(), Box<dyn Error>>, state: &Arc<Mutex<BracketState>>, case: &str) {
    let err = outcome.expect_err(&format!("{case}: the injected failure must fail the request"));
    assert!(
        err.to_string().contains("injected"),
        "{case}: the request must fail with the injected error, got {err}"
    );
    let state = state.lock().expect("state");
    assert!(
        !state.suppressed,
        "{case}: the request returned its error with the user's breakpoints still disabled"
    );
    assert!(
        state.temporaries.is_empty(),
        "{case}: the request returned its error with its temporary breakpoint still set: {:?}",
        state.temporaries
    );
}

#[test]
fn local_step_jump_restores_breakpoints_when_a_continue_fails_midway() {
    for nth in 1..=5 {
        let (mut handler, state) = handler_failing(Failure::Continue(nth));
        let (sender, _receiver) = mpsc::channel::<DapMessage>();
        let outcome = handler.local_step_jump(request("ct/local-step-jump"), loop_jump(), sender);
        assert_bracket_closed(outcome, &state, &format!("ct/local-step-jump, continue #{nth} fails"));
    }
}

#[test]
fn local_step_jump_restores_breakpoints_when_the_temporary_breakpoint_cannot_be_set() {
    let (mut handler, state) = handler_failing(Failure::AddBreakpoint);
    let (sender, _receiver) = mpsc::channel::<DapMessage>();
    let outcome = handler.local_step_jump(request("ct/local-step-jump"), loop_jump(), sender);
    assert_bracket_closed(outcome, &state, "ct/local-step-jump, add_breakpoint fails");
}

#[test]
fn local_step_jump_restores_breakpoints_when_the_temporary_breakpoint_cannot_be_deleted() {
    let (mut handler, state) = handler_failing(Failure::DeleteBreakpoint);
    let (sender, _receiver) = mpsc::channel::<DapMessage>();
    let outcome = handler.local_step_jump(request("ct/local-step-jump"), loop_jump(), sender);
    let err = outcome.expect_err("a failed delete must fail the request");
    assert!(err.to_string().contains("injected"), "got {err}");
    assert!(
        !state.lock().expect("state").suppressed,
        "a failed delete of the temporary breakpoint must not keep the user's breakpoints disabled"
    );
}

#[test]
fn source_line_jump_restores_breakpoints_when_the_temporary_breakpoint_cannot_be_set() {
    let (mut handler, state) = handler_failing(Failure::AddBreakpoint);
    let (sender, _receiver) = mpsc::channel::<DapMessage>();
    let target = SourceLocation {
        path: SOURCE_PATH.to_string(),
        line: 6,
        ..SourceLocation::default()
    };
    let outcome = handler.source_line_jump(request("ct/source-line-jump"), target, sender);
    assert_bracket_closed(outcome, &state, "ct/source-line-jump, add_breakpoint fails");
}

/// The request failed with the injected error, and before it did it brought
/// the handler's step up to date and reported the stop the replay was left
/// at: one `stopped` and one `ct/complete-move` at `position`, and no
/// response of its own (the task thread answers the error `success: false`).
fn assert_stop_reported(
    outcome: &Result<(), Box<dyn Error>>,
    handler: &Handler,
    messages: &mpsc::Receiver<DapMessage>,
    position: i64,
    case: &str,
) {
    let err = outcome
        .as_ref()
        .expect_err(&format!("{case}: the injected failure must fail the request"));
    assert!(
        err.to_string().contains("injected"),
        "{case}: the request must fail with the injected error, got {err}"
    );
    assert_eq!(
        handler.step_id,
        StepId(position),
        "{case}: the handler's step must be where the replay was left"
    );
    let mut stopped = 0;
    let mut complete_moves = vec![];
    for message in messages.try_iter() {
        match message {
            DapMessage::Event(event) if event.event == "stopped" => stopped += 1,
            DapMessage::Event(event) if event.event == "ct/complete-move" => {
                let state: MoveState = serde_json::from_value(event.body).expect("a MoveState body");
                complete_moves.push(state.location.rr_ticks.0);
            }
            DapMessage::Response(response) => {
                panic!("{case}: a failed request must not answer itself, got {response:?}")
            }
            _ => {}
        }
    }
    assert_eq!(stopped, 1, "{case}: the stop the replay was left at must be reported");
    assert_eq!(
        complete_moves,
        vec![position],
        "{case}: ct/complete-move must report the position the replay was left at"
    );
}

#[test]
fn local_step_jump_that_fails_midway_reports_where_it_left_the_replay() {
    for nth in 1..=5 {
        let (mut handler, state) = handler_failing(Failure::Continue(nth));
        let (sender, receiver) = mpsc::channel::<DapMessage>();
        let outcome = handler.local_step_jump(request("ct/local-step-jump"), loop_jump(), sender);
        let case = format!("ct/local-step-jump, continue #{nth} fails");
        // The `Continue`s before the failing one have moved the replay.
        assert_stop_reported(&outcome, &handler, &receiver, nth as i64 - 1, &case);
        assert_bracket_closed(outcome, &state, &case);
    }
}

#[test]
fn local_step_jump_whose_bracket_cannot_be_closed_reports_where_it_left_the_replay() {
    let (mut handler, state) = handler_failing(Failure::DeleteBreakpoint);
    let (sender, receiver) = mpsc::channel::<DapMessage>();
    let outcome = handler.local_step_jump(request("ct/local-step-jump"), loop_jump(), sender);
    // All five `Continue`s ran; closing the bracket is what failed.
    assert_stop_reported(
        &outcome,
        &handler,
        &receiver,
        5,
        "ct/local-step-jump, delete_breakpoint fails",
    );
    assert!(
        !state.lock().expect("state").suppressed,
        "a failed delete of the temporary breakpoint must not keep the user's breakpoints disabled"
    );
}

#[test]
fn source_line_jump_whose_bracket_cannot_be_closed_reports_where_it_left_the_replay() {
    let (mut handler, state) = handler_failing(Failure::DeleteBreakpoint);
    let (sender, receiver) = mpsc::channel::<DapMessage>();
    let target = SourceLocation {
        path: SOURCE_PATH.to_string(),
        line: 6,
        ..SourceLocation::default()
    };
    let outcome = handler.source_line_jump(request("ct/source-line-jump"), target, sender);
    // `Smart`: forward, which misses line 6 (the double stops on line 1),
    // then backward: two `Continue`s ran before closing the bracket failed.
    assert_stop_reported(
        &outcome,
        &handler,
        &receiver,
        2,
        "ct/source-line-jump, delete_breakpoint fails",
    );
    assert!(
        !state.lock().expect("state").suppressed,
        "a failed delete of the temporary breakpoint must not keep the user's breakpoints disabled"
    );
}

#[test]
fn step_whose_jit_registration_continue_fails_reports_where_it_left_the_replay() {
    // A live session continues past the internal JIT debug-symbol
    // registration stop a step can land on. Here the step in succeeds and
    // the first of those `Continue`s fails.
    let args = RecreatorArgs {
        live_program: Some(PathBuf::from("/test/workdir/main")),
        ..RecreatorArgs::default()
    };
    let (mut handler, _state) = handler_over(Failure::Continue(1), args, true);
    let (sender, receiver) = mpsc::channel::<DapMessage>();
    let outcome = handler.step(request("stepIn"), StepArg::new(Action::StepIn, false), sender);
    assert_stop_reported(
        &outcome,
        &handler,
        &receiver,
        1,
        "stepIn, the JIT registration continue fails",
    );
}
