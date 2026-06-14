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

    /// M2 — statement-granularity step-over.
    ///
    /// Advance by exactly one /statement/ rather than by one source
    /// /line/.  The default implementation falls back to the legacy
    /// line-granularity step (`step(Action::Next, forward)`) so that
    /// sessions without column data — emulator-backed MCR, recreator,
    /// etc. — see no behaviour change.  The materialised replay
    /// session overrides this to consult the recorded `DbStep.column`
    /// data and advance to the next recorded step at same-or-shallower
    /// call depth (each recorded step is its own statement under the
    /// column-aware recorder contract).
    ///
    /// Returns `true` when execution advanced, `false` when the cursor
    /// is already at the trace boundary and there is nothing to step
    /// to.  Mirrors the `step()` return shape so the DAP handler's
    /// limit-of-record notification works uniformly across granularities.
    ///
    /// Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M2.
    fn step_over_statement(&mut self, forward: bool) -> Result<bool, Box<dyn Error>> {
        self.step(Action::Next, forward)
    }

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

    /// Register a breakpoint at `(path, line[, column])`.
    ///
    /// `column` is `Some(c)` for the M1 column-aware path (matches a
    /// recorded `DbStep` whose `(line, column)` equals the breakpoint
    /// coordinates) and `None` for the legacy line-only path (matches
    /// any step on the line, regardless of column).  Implementations
    /// MUST keep the legacy line-only behaviour intact when `column`
    /// is `None`.
    fn add_breakpoint(&mut self, path: &str, line: i64, column: Option<i64>) -> Result<Breakpoint, Box<dyn Error>>;
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

    /// Return the latest replayable position for a live recording.
    fn recording_head(&mut self) -> Result<u64, Box<dyn Error>> {
        Err("recording head is only available for live replay sessions".into())
    }

    /// Restore the debugger/replay state to a recorded live position.
    fn restore_at(
        &mut self,
        geid: u64,
        tid: Option<u32>,
        tick: Option<u64>,
        phase: Option<String>,
    ) -> Result<bool, Box<dyn Error>> {
        let _ = (geid, tid, tick, phase);
        Err("restore-at is only available for live replay sessions".into())
    }

    /// Seek to a GEID-backed event position.
    fn seek_to_geid(&mut self, geid: u64) -> Result<bool, Box<dyn Error>> {
        self.restore_at(geid, None, None, None)
    }

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

    /// Downcast hook used by `Handler::origin_chain` to call into the
    /// concrete `MaterializedReplaySession::origin_chain_inferred` (M2).
    /// The default implementation returns `None` so non-materialized
    /// sessions surface the DAP 6103 error without further plumbing.
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any;

    /// M18 — surface the trace's omniscient DB when one is available
    /// (i.e. the recorder shipped a `memwrites.tc` / `linehits.tc`
    /// namespace in the CTFS container). Origin queries (M20) and
    /// `db.rs::load_history` consult this through the trait so they
    /// stay backend-agnostic; sessions without an omniscient log
    /// return `None` and callers fall back to their per-backend path.
    fn omniscient_db(&self) -> Option<&dyn crate::omniscient_db::OmniscientDb> {
        None
    }

    /// M22 — arm a per-write data breakpoint on
    /// `[address, address + size)`. Returns the new handle on success.
    /// Default impl returns
    /// [`crate::data_watch::DataWatchError::InvalidSize`] so non-emulator
    /// backends surface a typed error rather than crashing — they have
    /// no per-write probe to wire into. The [`EmulatorReplaySession`]
    /// override forwards to the Nim-side `mcrDataWatchInstall` shim per
    /// spec §6.6 (browser-replay path).
    fn data_watch_install(
        &mut self,
        address: u64,
        size: u32,
    ) -> Result<crate::data_watch::DataWatchHandle, crate::data_watch::DataWatchError> {
        let _ = (address, size);
        Err(crate::data_watch::DataWatchError::InvalidSize(size))
    }

    /// M22 — tear down a previously-installed data watch. Default impl
    /// surfaces [`crate::data_watch::DataWatchError::UnknownHandle`]
    /// because non-emulator backends never minted the handle in the
    /// first place.
    fn data_watch_clear(
        &mut self,
        handle: crate::data_watch::DataWatchHandle,
    ) -> Result<(), crate::data_watch::DataWatchError> {
        Err(crate::data_watch::DataWatchError::UnknownHandle(handle.raw()))
    }

    /// M22 — session-scoped reset: tear down every armed watch and
    /// reset the per-session counters. Called by the origin algorithm
    /// at the top of an origin-chain build to make sure leaked watches
    /// from a previous query never cross-talk into the next one.
    /// Default impl is a no-op for backends that don't support the
    /// primitive.
    fn data_watch_reset(&mut self) {}
}
