use codetracer_trace_types::StepId;
use std::error::Error;

use crate::db::DbRecordEvent;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
use crate::task::{
    Action, Breakpoint, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg, Location,
    ProcessInfo, ProgramEvent, VariableWithRecord,
};
use crate::value::ValueRecordWithType;

pub trait ReplaySession: std::fmt::Debug {
    fn load_location(&mut self, expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>>;

    /// Returns the C-level location from the last `load_location` call, if available.
    ///
    /// For sourcemapped languages (e.g. Nim compiled to C), this returns the
    /// generated C location that was extracted alongside the high-level location.
    /// For non-sourcemapped languages, returns `None`.
    fn last_c_location(&self) -> Option<Location> {
        None
    }
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
    fn load_history(&mut self, arg: &LoadHistoryArg) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>>;

    fn add_breakpoint(&mut self, path: &str, line: i64) -> Result<Breakpoint, Box<dyn Error>>;
    fn delete_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>>;
    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>>;
    fn toggle_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn Error>>;
    fn enable_breakpoints(&mut self) -> Result<(), Box<dyn Error>>;
    fn disable_breakpoints(&mut self) -> Result<(), Box<dyn Error>>;

    fn jump_to(&mut self, step_id: StepId) -> Result<bool, Box<dyn Error>>;
    fn jump_to_call(&mut self, location: &Location) -> Result<Location, Box<dyn Error>>;
    fn event_jump(&mut self, event: &ProgramEvent) -> Result<bool, Box<dyn Error>>;
    fn callstack_jump(&mut self, depth: usize) -> Result<(), Box<dyn Error>>;
    fn location_jump(&mut self, location: &Location) -> Result<(), Box<dyn Error>>;
    fn tracepoint_jump(&mut self, event: &ProgramEvent) -> Result<(), Box<dyn Error>>;
    fn evaluate_call_expression(
        &mut self,
        call_expression: &str,
        lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>>;

    fn current_step_id(&mut self) -> StepId;

    /// Enumerate the processes captured in this trace.
    ///
    /// Multi-process traces (fork / exec) record multiple processes; this
    /// method returns one [`ProcessInfo`] per recorded process. The DAP
    /// `threads` handler maps each entry to a `Thread { id: pid, name }`
    /// so that DAP clients see one thread per process.
    ///
    /// For single-process recordings (or backends that do not track per-
    /// process metadata) the default implementation returns a synthetic
    /// single-entry vector with `pid = 0` and `command = "main"`. This
    /// preserves the historical "one thread" behavior for non-multiprocess
    /// traces without weakening the multi-process case.
    ///
    /// Implementations that talk to a replay worker (RR / MCR) should
    /// override this method to forward a `GetProcessInfo` query and parse
    /// the returned `Vec<ProcessInfo>`.
    fn list_processes(&mut self) -> Result<Vec<ProcessInfo>, Box<dyn Error>> {
        Ok(vec![ProcessInfo {
            pid: 0,
            ppid: 0,
            exit_code: None,
            command: "main".to_string(),
        }])
    }
}
