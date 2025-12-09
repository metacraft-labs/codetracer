use runtime_tracing::StepId;
use std::error::Error;

use crate::db::DbRecordEvent;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
use crate::task::{
    Action, Breakpoint, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg, Location,
    ProgramEvent, VariableWithRecord,
};
use crate::value::ValueRecordWithType;

pub trait Replay: std::fmt::Debug {
    fn load_location(&mut self, expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>>;
    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>>;
    fn load_events(&mut self) -> Result<Events, Box<dyn Error>>;
    fn step(&mut self, action: Action, forward: bool) -> Result<bool, Box<dyn Error>>;
    fn load_locals(&mut self, arg: CtLoadLocalsArguments) -> Result<Vec<VariableWithRecord>, Box<dyn Error>>;

    // currently depth_limit, lang only used for rr!
    // for db returning full values in their existing form
    fn load_value(
        &mut self,
        expression: &str,
        depth_limit: Option<usize>,
        lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>>;

    // assuming currently the replay is stopped in the right `call`(frame) for both trace kinds;
    //   and if rr: possibly near the return value
    // currently depth_limit, lang only used for rr!
    // for db returning full values in their existing form
    fn load_return_value(
        &mut self,
        depth_limit: Option<usize>,
        lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>>;

    fn load_step_events(&mut self, step_id: StepId, exact: bool) -> Vec<DbRecordEvent>;
    fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn Error>>;
    fn load_history(&mut self, arg: &LoadHistoryArg) -> Result<Vec<HistoryResultWithRecord>, Box<dyn Error>>;

    fn jump_to(&mut self, step_id: StepId) -> Result<bool, Box<dyn Error>>;
    fn add_breakpoint(&mut self, path: &str, line: i64) -> Result<Breakpoint, Box<dyn Error>>;
    fn delete_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>>;
    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>>;
    fn toggle_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn Error>>;
    fn enable_breakpoints(&mut self) -> Result<(), Box<dyn Error>>;
    fn disable_breakpoints(&mut self) -> Result<(), Box<dyn Error>>;
    fn jump_to_call(&mut self, location: &Location) -> Result<Location, Box<dyn Error>>;
    fn event_jump(&mut self, event: &ProgramEvent) -> Result<bool, Box<dyn Error>>;
    fn callstack_jump(&mut self, depth: usize) -> Result<(), Box<dyn Error>>;

    fn tracepoint_jump(&mut self, event: &ProgramEvent) -> Result<(), Box<dyn Error>>;

    fn current_step_id(&mut self) -> StepId;
}
