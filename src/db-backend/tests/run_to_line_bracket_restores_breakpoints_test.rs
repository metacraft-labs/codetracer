//! A move that fails part-way leaves the user's breakpoints as they were.
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
//! ## Why a test double stands in for the replay session
//!
//! [`BracketReplay`] replaces the trace's `ReplaySession` and keeps the two
//! facts this pins — whether the user's breakpoints are suppressed, and
//! which temporary breakpoints are set — failing the one call each case
//! names. The production session for these traces is an rr replay driven
//! through the `ct-native-replay` worker from the sibling
//! `codetracer-native-backend` repository. A real worker cannot be made to
//! fail a chosen `Continue` (or a chosen breakpoint operation) on demand, and
//! the defect is entirely in the handler's bookkeeping around those calls,
//! not in the worker. So the double supplies the calls' outcomes and nothing
//! else; every trait method the bracket does not use is unreachable and
//! panics if called.

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
    LocalStepJump, Location, ProgramEvent, SourceLocation, TraceKind, VariableWithRecord,
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
}

/// A `ReplaySession` that answers the run-to-line bracket only. See the
/// module documentation for why it is a double.
#[derive(Debug)]
struct BracketReplay {
    state: Arc<Mutex<BracketState>>,
    fail: Failure,
}

const ONLY_THE_BRACKET: &str = "BracketReplay answers the run-to-line bracket only";

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
        assert!(matches!(action, Action::Continue), "the bracket only continues");
        let mut state = self.state.lock().expect("state");
        state.continues += 1;
        if let Failure::Continue(n) = self.fail
            && state.continues == n
        {
            return Err(format!("injected: continue #{n} failed").into());
        }
        Ok(true)
    }
    fn load_location(&mut self, _expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
        Ok(Location {
            path: SOURCE_PATH.to_string(),
            line: 1,
            ..Location::default()
        })
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
    fn current_step_id(&mut self) -> StepId {
        unreachable!("{ONLY_THE_BRACKET}")
    }
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

/// An rr-kind handler over the double, and the state the double keeps.
fn handler_failing(fail: Failure) -> (Handler, Arc<Mutex<BracketState>>) {
    let state = Arc::new(Mutex::new(BracketState::default()));
    let handler = Handler::construct_with_replay(
        TraceKind::Recreator,
        RecreatorArgs::default(),
        Arc::new(InMemoryTraceReader::new(Db::new(&PathBuf::from("/test/workdir")))),
        Box::new(BracketReplay {
            state: Arc::clone(&state),
            fail,
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
