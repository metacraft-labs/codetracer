//! [`EmulatorReplaySession`] — `ReplaySession` impl backed by the Nim MCR
//! emulator (F5c-1, native target only).
//!
//! ## Scope
//!
//! This file is the F5c-1 deliverable: it exists primarily to prove the
//! Nim → C → Rust pipeline links and the Nim runtime initialises cleanly.
//! All trait methods are stubbed with `todo!()` so the trait surface is
//! satisfied without the caller ever invoking them.
//!
//! Subsequent milestones:
//! - F5c-2 wires the same wrapper through wasm32 (emcc/wasm-bindgen).
//! - F5c-3 implements real `ReplaySession` behaviour against the emulator.
//! - F5c-4 routes MCR traces in `dap_server::setup_from_vfs` to this type
//!   instead of returning the FlagHasMcrFields rejection.
//!
//! ## Initialisation invariant
//!
//! Nim's exported procs require the runtime to be initialised exactly once
//! per process via `NimMain`. We guard that with [`std::sync::Once`] so
//! that constructing multiple sessions (e.g. during testing) is safe.
//! `mcrInit` itself is idempotent and is called on every `new()` so each
//! session starts from a clean emulator state.

#![cfg(not(target_arch = "wasm32"))]

use codetracer_trace_types::StepId;
use std::error::Error;
use std::sync::Once;

use crate::db::DbRecordEvent;
use crate::emulator_ffi;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
use crate::replay::ReplaySession;
use crate::task::{
    Action, Breakpoint, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg, Location,
    ProgramEvent, VariableWithRecord,
};
use crate::value::ValueRecordWithType;

static NIM_RUNTIME_INIT: Once = Once::new();

/// Initialise the Nim runtime exactly once per process.
fn ensure_nim_runtime() {
    NIM_RUNTIME_INIT.call_once(|| {
        // SAFETY: NimMain is the standard Nim runtime entry point. It is
        // safe to call from a single thread once per process; the Once
        // guard guarantees that exclusivity.
        unsafe { emulator_ffi::NimMain() };
    });
}

/// `ReplaySession` backed by the Nim MCR emulator. F5c-1 stub: the trait
/// methods all `todo!()`; F5c-3 fills them in.
#[derive(Debug)]
pub struct EmulatorReplaySession {
    /// Last reported step. The emulator owns the real PC/registers; this
    /// is just a placeholder so `current_step_id` has a sensible default
    /// before F5c-3 wires real step tracking.
    current_step_id: StepId,
}

impl EmulatorReplaySession {
    /// Create a new session backed by a freshly-initialised Nim emulator.
    ///
    /// The first call also initialises the Nim runtime via `NimMain`.
    pub fn new() -> Self {
        ensure_nim_runtime();
        // SAFETY: mcrInit is safe to call after NimMain has run and is
        // idempotent — it merely resets the emulator's globals.
        unsafe { emulator_ffi::mcrInit() };
        Self {
            current_step_id: StepId(0),
        }
    }
}

impl Default for EmulatorReplaySession {
    fn default() -> Self {
        Self::new()
    }
}

impl ReplaySession for EmulatorReplaySession {
    fn load_location(&mut self, _expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
        todo!("F5c-3: derive Location from emulator PC + sourcemap")
    }

    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        todo!("F5c-3: drive emulator to program entry point")
    }

    fn load_events(&mut self) -> Result<Events, Box<dyn Error>> {
        todo!("F5c-3: project emulator syscall log into Events")
    }

    fn step(&mut self, _action: Action, _forward: bool) -> Result<bool, Box<dyn Error>> {
        todo!("F5c-3: map DAP step actions onto mcrStep / mcrRun")
    }

    fn load_locals(&mut self, _arg: CtLoadLocalsArguments) -> Result<Vec<VariableWithRecord>, Box<dyn Error>> {
        todo!("F5c-3: walk frame locals via DWARF + emulator memory")
    }

    fn load_value(
        &mut self,
        _expression: &str,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        todo!("F5c-3: evaluate expressions via the emulator")
    }

    fn load_return_value(
        &mut self,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        todo!("F5c-3: report return value from emulator state")
    }

    fn load_step_events(&mut self, _step_id: StepId, _exact: bool) -> Vec<DbRecordEvent> {
        todo!("F5c-3: gather events recorded at a given step")
    }

    fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn Error>> {
        todo!("F5c-3: unwind callstack from emulator registers / memory")
    }

    fn load_history(&mut self, _arg: &LoadHistoryArg) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>> {
        todo!("F5c-3: build per-line history from emulator trace")
    }

    fn add_breakpoint(&mut self, _path: &str, _line: i64) -> Result<Breakpoint, Box<dyn Error>> {
        todo!("F5c-3: translate path/line into PC and arm emulator breakpoint")
    }

    fn delete_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>> {
        todo!("F5c-3: disarm emulator breakpoint")
    }

    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>> {
        todo!("F5c-3: clear all emulator breakpoints")
    }

    fn toggle_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn Error>> {
        todo!("F5c-3: flip emulator breakpoint state")
    }

    fn enable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        todo!("F5c-3: re-enable all suspended emulator breakpoints")
    }

    fn disable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        todo!("F5c-3: suspend all emulator breakpoints")
    }

    fn jump_to(&mut self, _step_id: StepId) -> Result<bool, Box<dyn Error>> {
        todo!("F5c-3: rewind/fast-forward emulator to step_id")
    }

    fn jump_to_call(&mut self, _location: &Location) -> Result<Location, Box<dyn Error>> {
        todo!("F5c-3: jump to enclosing call entry")
    }

    fn event_jump(&mut self, _event: &ProgramEvent) -> Result<bool, Box<dyn Error>> {
        todo!("F5c-3: replay to the step that produced `event`")
    }

    fn callstack_jump(&mut self, _depth: usize) -> Result<(), Box<dyn Error>> {
        todo!("F5c-3: pop to caller at `depth`")
    }

    fn location_jump(&mut self, _location: &Location) -> Result<(), Box<dyn Error>> {
        todo!("F5c-3: jump to a specific source location")
    }

    fn tracepoint_jump(&mut self, _event: &ProgramEvent) -> Result<(), Box<dyn Error>> {
        todo!("F5c-3: jump to a tracepoint event")
    }

    fn evaluate_call_expression(
        &mut self,
        _call_expression: &str,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        todo!("F5c-3: evaluate a `func(args)` expression via the emulator")
    }

    fn current_step_id(&mut self) -> StepId {
        self.current_step_id
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// F5c-1 bring-up: constructing the session must succeed (NimMain plus
    /// mcrInit linked and callable). Probing the emulator state via the FFI
    /// should report zeros, since we have not loaded a program.
    #[test]
    fn new_session_initialises_nim_runtime_and_resets_state() {
        let mut session = EmulatorReplaySession::new();

        // SAFETY: After `new()` the Nim runtime is initialised and mcrInit
        // has been called; these getters are safe to invoke and return 0
        // because no register file has been loaded yet.
        unsafe {
            assert_eq!(emulator_ffi::mcrGetPC(), 0);
            assert_eq!(emulator_ffi::mcrGetSP(), 0);
            assert_eq!(emulator_ffi::mcrGetRegister(0), 0);
            assert_eq!(emulator_ffi::mcrGetStepCounter(), 0);
        }

        // current_step_id is the only trait method with a non-`todo!()`
        // body in F5c-1; sanity-check that it returns the initial value.
        assert_eq!(session.current_step_id(), StepId(0));
    }
}
