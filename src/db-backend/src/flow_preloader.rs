use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::path::{Path, PathBuf};

use codetracer_trace_types::{CallKey, Line, NO_KEY, StepId, TypeKind, TypeRecord, TypeSpecificInfo};
use log::{error, info, warn};

use crate::{
    db::DbRecordEvent,
    expr_loader::ExprLoader,
    lang::{Lang, lang_from_context},
    nim_mangling,
    replay::ReplaySession,
    task::{
        Action, BranchesTaken, CoreTrace, CtLoadLocalsArguments, FlowEvent, FlowMode, FlowStep, FlowUpdate,
        FlowUpdateState, FlowUpdateStateKind, FlowViewUpdate, Iteration, Location, Loop, LoopId, LoopIterationSteps,
        Position, RRTicks, StepCount, TraceKind,
    },
    value::{Value, ValueRecordWithType, to_ct_value},
};

const STEP_COUNT_LIMIT: usize = 10000;
const RETURN_VALUE_RR_DEPTH_LIMIT: usize = 7;
const LOAD_FLOW_VALUE_RR_DEPTH_LIMIT: usize = 2;

fn should_enter_materialized_call_body(location: &Location) -> bool {
    location.rr_ticks.0 > 0 || (location.rr_ticks.0 == 0 && location.line > 0)
}

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

    pub fn load(
        &mut self,
        location: Location,
        mode: FlowMode,
        kind: TraceKind,
        replay: &mut dyn ReplaySession,
    ) -> FlowUpdate {
        info!("flow: load: {:?}", location);
        let path_buf = PathBuf::from(&location.path);

        // CODETRACER_DISABLE_TREESITTER=1 forces the trace-embedded variable
        // fallback path, bypassing tree-sitter parsing entirely.  Useful for
        // testing the fallback and for languages whose tree-sitter grammars
        // are immature or produce incorrect ASTs.
        let treesitter_disabled = std::env::var("CODETRACER_DISABLE_TREESITTER")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);

        if treesitter_disabled {
            info!("  tree-sitter disabled via CODETRACER_DISABLE_TREESITTER — using trace-embedded variables");
        } else {
            match self.expr_loader.load_file(&path_buf) {
                Ok(_) => {
                    info!("  expression loader complete!");
                }
                Err(e) => {
                    // Tree-sitter parsing failed for this file.
                    // Continue loading the flow anyway — the fallback in log_expressions() will use
                    // trace-embedded variable data instead of tree-sitter-extracted names.
                    info!(
                        "  tree-sitter parse failed for {}: {} — will use trace-embedded variables",
                        location.path, e
                    );
                }
            }
        }
        let mut call_flow_preloader: CallFlowPreloader =
            CallFlowPreloader::new(self, location.clone(), HashSet::new(), HashSet::new(), mode, kind);
        call_flow_preloader.load_flow(location, replay)
    }

    pub fn load_diff_flow(
        &mut self,
        diff_lines: HashSet<(PathBuf, i64)>,
        reader: &dyn crate::trace_reader::TraceReader,
        trace_kind: TraceKind,
        replay: &mut dyn ReplaySession,
    ) -> Result<FlowUpdate, Box<dyn Error>> {
        info!("load_diff_flow");
        for diff_line in &diff_lines {
            match self.expr_loader.load_file(&diff_line.0) {
                Ok(_) => {
                    continue;
                }
                Err(e) => {
                    warn!("can't process file {}: error {}", diff_line.0.display(), e);
                    return Err(format!("can't process file {}", diff_line.0.display()).into());
                    // FlowUpdate::error(&format!("can't process file {}", diff_line.0.display()));
                }
            }
        }

        let mut diff_call_keys = HashSet::new();
        // put breakpoints on all of them
        for diff_line in &diff_lines {
            let _ = replay.add_breakpoint(&diff_line.0.display().to_string(), diff_line.1, None, None)?;
        }
        // TODO: breakpoints on function entries or function names as well
        //   so => we can count how many stops?
        //
        // just continue for now in next diff flow step; and if we go through the function/function entry line or
        // breakpoint; count a next call for it;
        // maybe this will just work because they're registered as loop first line

        for step_idx in 0..reader.step_count() {
            let step_id = codetracer_trace_types::StepId(step_idx as i64);
            if let Some(step) = reader.step(step_id) {
                let path_str = reader.path(step.path_id).unwrap_or("");
                if diff_lines.contains(&(PathBuf::from(path_str), step.line.0)) {
                    diff_call_keys.insert(step.call_key.0);
                    let location = reader.load_location(step.step_id, step.call_key, &mut self.expr_loader);
                    // register an artifficial loop for each function from the diff,
                    //   that we track, so we can visualize different global calls to those functions
                    //   with sliders/count etc:
                    self.expr_loader.register_loop(
                        Position(location.function_first),
                        Position(location.function_last),
                        &PathBuf::from(path_str),
                    );
                }
            }
        }

        let mut call_flow_preloader = CallFlowPreloader::new(
            self,
            Location::default(),
            diff_lines,
            diff_call_keys,
            FlowMode::Diff,
            trace_kind,
        );
        let location = Location {
            line: 1,
            ..Location::default()
        };
        Ok(call_flow_preloader.load_flow(location, replay))
    }

    // fn load_file(&mut self, path: &str) {
    // self.expr_loader.load_file(&PathBuf::from(path.to_string())).unwrap();
    // }

    pub fn get_var_list(&self, line: Position, location: &Location) -> Option<Vec<String>> {
        self.expr_loader.get_expr_list(line, location)
    }

    // fn get_function_location(&self, location: &Location, line: &Line) -> Location {
    // self.expr_loader.find_function_location(location, line)
    // }
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
    trace_kind: TraceKind,
    lang: Lang,
}

impl<'a> CallFlowPreloader<'a> {
    pub fn new(
        flow_preloader: &'a FlowPreloader,
        location: Location,
        diff_lines: HashSet<(PathBuf, i64)>,
        diff_call_keys: HashSet<i64>,
        mode: FlowMode,
        trace_kind: TraceKind,
    ) -> Self {
        CallFlowPreloader {
            flow_preloader,
            location: location.clone(),
            active_loops: vec![],
            last_step_id: StepId(-1),
            last_expr_order: vec![],
            diff_lines,
            diff_call_keys,
            mode,
            trace_kind,
            lang: lang_from_context(Path::new(&location.path), trace_kind),
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
    pub fn load_flow(&mut self, location: Location, replay: &mut dyn ReplaySession) -> FlowUpdate {
        // Update location on flow load
        if self.mode == FlowMode::Call {
            // let step_id = StepId(location.rr_ticks.0);
            // let call_key = self.db.steps[step_id].call_key;
            // let function_id = self.db.calls[call_key].function_id;
            // let function_first = self.db.functions[function_id].line;
            // info!("load {arg:?}");

            // BEAM languages (Elixir + Erlang) share the codetracer-beam-recorder
            // CTFS layout where the trace already encodes per-line steps inside
            // the active call frame and the location passed in already points at
            // the right step. Skip the tree-sitter `find_function_location` /
            // `jump_to_call` dance that the other materialized languages need.
            if self.trace_kind == TraceKind::Materialized && (self.lang == Lang::Elixir || self.lang == Lang::Erlang) {
                self.location = location.clone();
            } else {
                let original_ticks = location.rr_ticks.clone();
                let original_event = location.event;
                self.location = self
                    .flow_preloader
                    .expr_loader
                    .find_function_location(&location, &Line(location.line));
                // Preserve rr_ticks and event from the original location so
                // that RR/TTD flow workers can seek to the correct trace
                // position.  find_function_location only knows about source
                // boundaries and defaults these to zero.
                if self.location.rr_ticks.0 == 0 && original_ticks.0 != 0 {
                    self.location.rr_ticks = original_ticks;
                }
                if self.location.event == 0 && original_event != 0 {
                    self.location.event = original_event;
                }
                // When tree-sitter can't determine function boundaries (no grammar, parse
                // failure, or the line doesn't fall inside any function in the AST), fall back
                // to the boundaries from the incoming location.  The handler enriches the
                // location with Db-derived boundaries before calling load(), so this should
                // give valid boundaries even without tree-sitter.
                if self.location.function_first == 0 && self.location.function_last == 0 {
                    info!(
                        "  find_function_location returned (0,0) — using incoming location boundaries ({}, {})",
                        location.function_first, location.function_last
                    );
                    self.location.function_first = location.function_first;
                    self.location.function_last = location.function_last;
                    self.location.function_name = location.function_name.clone();
                    self.location.high_level_function_name = location.high_level_function_name.clone();
                }
            }

            // For DB traces, the flow should cover the entire function call,
            // not just from the breakpoint forward. Use jump_to_call to find
            // the call's first step, then step with StepIn to enter the body.
            if self.trace_kind == TraceKind::Materialized
                && self.lang != Lang::Elixir
                && self.lang != Lang::Erlang
                && should_enter_materialized_call_body(&self.location)
                && let Ok(call_loc) = replay.jump_to_call(&self.location)
            {
                // jump_to_call lands on the call entry step (the Call
                // event itself). StepIn from there enters the call body.
                if replay.step(Action::StepIn, true).is_ok() {
                    let step_id = replay.current_step_id();
                    info!(
                        "  flow: entered call body at step {} (from call entry at step {})",
                        step_id.0, call_loc.rr_ticks.0
                    );
                    self.location.rr_ticks = RRTicks(step_id.0);
                }
            }
        }

        // info!("location flow {:?}", self.location);

        match self.load_view_update(replay) {
            Ok(flow_view_update) => {
                let mut flow_update = FlowUpdate::new();
                flow_update.location = self.location.clone();
                flow_update.view_updates.push(flow_view_update);
                flow_update.status = FlowUpdateState {
                    kind: FlowUpdateStateKind::FlowFinished,
                    steps: 0,
                };
                flow_update
            }
            Err(e) => {
                error!("flow error: {e:?}");
                FlowUpdate::error(&format!("{:?}", e))
            }
        }
    }

    fn add_return_value(
        &mut self,
        mut flow_view_update: FlowViewUpdate,
        replay: &mut dyn ReplaySession,
    ) -> FlowViewUpdate {
        // assumes that replay is stopped on the place where return value is available

        let return_string = "return".to_string();

        // The if condition ensures, that the Options on which .unwrap() is called
        // are never None, so it is safe to unwrap them.
        if !flow_view_update.steps.is_empty() {
            info!("  try to load return value");
            let return_value_record = replay
                .load_return_value(Some(RETURN_VALUE_RR_DEPTH_LIMIT), self.lang)
                .unwrap_or(ValueRecordWithType::Error {
                    msg: "<return value error>".to_string(),
                    typ: TypeRecord {
                        kind: TypeKind::Error,
                        lang_type: "<error>".to_string(),
                        specific_info: TypeSpecificInfo::None,
                    },
                });
            let return_value = to_ct_value(&return_value_record);
            info!("  return value: {:?}", return_value);

            #[allow(clippy::unwrap_used)]
            flow_view_update
                .steps
                .last_mut()
                .unwrap()
                .before_values
                .insert(return_string.clone(), return_value.clone());

            #[allow(clippy::unwrap_used)]
            flow_view_update
                .steps
                .last_mut()
                .unwrap()
                .expr_order
                .push(return_string.clone());

            #[allow(clippy::unwrap_used)]
            flow_view_update
                .steps
                .first_mut()
                .unwrap()
                .before_values
                .insert(return_string.clone(), return_value.clone());

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

    fn next_diff_flow_step(
        &self,
        _from_step_id: StepId,
        _including_from: bool,
        _replay: &mut dyn ReplaySession,
    ) -> (StepId, bool, bool) {
        // TODO: maybe combination of replay.next, diff_call_keys check, different for cases?s
        //
        // if from_step_id.0 >= db.steps.len() as i64 {
        //     (from_step_id, false)
        // } else {
        //     // TODO: next diff step
        //     let mut next_step_id = if !including_from { from_step_id + 1 } else { from_step_id };
        //     loop {
        //         if next_step_id.0 >= db.steps.len() as i64 { // must be + 1! then we assume we should stay and report not progressing
        //             return (from_step_id, false);
        //         }
        //         let next_step = db.steps[next_step_id];
        //         info!("check {:?}", (PathBuf::from(db.paths[next_step.path_id].clone()), next_step.line.0));
        //         if self.diff_call_keys.contains(&next_step.call_key.0) {
        //             // &(PathBuf::from(db.paths[next_step.path_id].clone()), next_step.line.0)) {
        //             return (next_step_id, true);
        //         } else {
        //             next_step_id = next_step_id + 1;
        //             continue;
        //         }
        //     }
        // }
        todo!()
    }

    fn move_to_first_step(
        &self,
        from_step_id: StepId,
        replay: &mut dyn ReplaySession,
    ) -> Result<(StepId, bool, bool), Box<dyn Error>> {
        let (mut step_id, mut progressing, mut move_error) = match self.mode {
            FlowMode::Call => (from_step_id, true, false),
            FlowMode::Diff => self.next_diff_flow_step(StepId(0), true, replay),
        };
        if self.trace_kind == TraceKind::Materialized {
            // For materialized traces the frontend usually sends an exact rrTicks for the
            // current stop, while some API callers only provide a source line.
            // When step_id is non-zero the caller already knows the exact step
            // (e.g. from a DAP breakpoint hit) — we just jump there directly.
            // When step_id is 0, only a source line was provided: we set a
            // temporary breakpoint to reach it, then jump_to_call to widen the
            // flow to the enclosing call entry.
            if step_id.0 == 0 && self.mode == FlowMode::Call && self.location.line > 0 {
                replay.jump_to(StepId(0))?;
                let bp = replay.add_breakpoint(&self.location.path, self.location.line, None, None)?;
                let hit = replay.step(Action::Continue, true)?;
                let _ = replay.delete_breakpoint(&bp);
                if hit {
                    let mut expr_loader = ExprLoader::new(CoreTrace::default());
                    let at_line_loc = replay.load_location(&mut expr_loader)?;
                    match replay.jump_to_call(&at_line_loc) {
                        Ok(call_start_loc) => {
                            step_id = StepId(call_start_loc.rr_ticks.0);
                            info!(
                                "  flow: navigated to function call entry at step {} (line {})",
                                step_id.0, call_start_loc.line
                            );
                        }
                        Err(e) => {
                            warn!("  flow: jump_to_call failed after breakpoint hit: {e:?}");
                            step_id = replay.current_step_id();
                        }
                    }
                } else {
                    warn!("  flow: breakpoint at line {} was never hit", self.location.line);
                    move_error = true;
                }
            } else {
                replay.jump_to(step_id)?;
            }
        } else {
            // For RR traces we still need to resolve the current stop first so
            // function flow is scoped to the active call, but once that stop is
            // resolved we should still widen to the enclosing call entry.
            // Check both rr_ticks and event: Delve (Go) can't provide ticks but does
            // provide event numbers, which ct-native-replay uses as a fallback for seeking.
            if (self.location.rr_ticks.0 > 0 || self.location.event > 0) && self.location.line > 0 {
                info!(
                    "  move_to_first_step: jumping to location at line {} rr_ticks={} event={}",
                    self.location.line, self.location.rr_ticks.0, self.location.event
                );
                if let Err(e) = replay.location_jump(&self.location) {
                    warn!("  location_jump error: {e:?}, falling back to jump_to_call");
                    if let Ok(location) = replay.jump_to_call(&self.location) {
                        step_id = StepId(location.rr_ticks.0);
                        progressing = true;
                    } else {
                        move_error = true;
                    }
                } else {
                    let mut expr_loader = ExprLoader::new(CoreTrace::default());
                    match replay.load_location(&mut expr_loader) {
                        Ok(current_location) => match replay.jump_to_call(&current_location) {
                            Ok(call_start_loc) => {
                                step_id = StepId(call_start_loc.rr_ticks.0);
                                progressing = true;
                                info!(
                                    "  flow: navigated to function call entry at step {} (line {})",
                                    step_id.0, call_start_loc.line
                                );
                            }
                            Err(e) => {
                                warn!("  flow: jump_to_call failed, keeping current flow start: {e:?}");
                                step_id = replay.current_step_id();
                                progressing = true;
                            }
                        },
                        Err(e) => {
                            warn!("  flow: load_location after location_jump failed: {e:?}");
                            step_id = replay.current_step_id();
                            progressing = true;
                        }
                    }
                }
            } else if let Ok(location) = replay.jump_to_call(&self.location) {
                step_id = StepId(location.rr_ticks.0);
                progressing = true;
            } else {
                // Fallback for TTD traces where jump_to_call is not yet
                // supported: run_to_entry navigates the flow worker to the
                // program entry point (main) so the flow loop can start
                // stepping from there.
                info!("  flow: jump_to_call failed, falling back to run_to_entry");
                if let Ok(()) = replay.run_to_entry() {
                    step_id = replay.current_step_id();
                    progressing = true;
                } else {
                    move_error = true;
                }
            }
        }
        Ok((step_id, progressing, move_error))
    }

    // returns new step_id/rr ticks(?) and `progressing`(if false, the flow loop should stop)
    //   for RR: rr ticks might stay the same, but we still return progressing `true` unless we have an error for
    //      stepping/location
    fn move_to_next_step(&mut self, from_step_id: StepId, replay: &mut dyn ReplaySession) -> (StepId, bool, bool) {
        info!("  move_to_next_step:");
        match self.mode {
            FlowMode::Call => {
                // let step_to_different_line = true; // for flow for now makes sense to try to always reach a new line
                if let Err(e) = replay.step(Action::Next, true) {
                    // this might not really be a problem: we just need to stop the flow after this:
                    warn!("    `next` error: {e:}");
                    return (from_step_id, false, true); // assume we will break the flow loop if `progressing` is false
                }

                let mut expr_loader = ExprLoader::new(CoreTrace::default());
                // for MaterializedReplaySession actually those replay methods shouldn't fail;
                //   but this might be unreliable/change in the future
                //   and for RR they can also surely fail
                match replay.load_location(&mut expr_loader) {
                    Ok(location) => {
                        let new_step_id = StepId(location.rr_ticks.0);
                        let progressing = if self.trace_kind == TraceKind::Materialized {
                            new_step_id != from_step_id
                        } else {
                            // for now hard to detect; assume true
                            //   we tried `new_step_id != from_step_id;`, but this is incorrect:
                            //   often rr ticks can be the same for many different lines.. maybe detect signal or
                            //   hope that difference in call key/other aspects will be enough!
                            true
                        };
                        (new_step_id, progressing, false)
                    }
                    Err(e) => {
                        warn!("    `load_location` error: {e:}");
                        // assume we will break the flow loop if `progressing` is false
                        (from_step_id, false, true)
                    }
                }
            }
            FlowMode::Diff => self.next_diff_flow_step(from_step_id, false, replay),
        }
    }

    fn call_key_from(&self, location: &Location) -> Result<CallKey, Box<dyn Error>> {
        Ok(CallKey(location.key.parse::<i64>()?)) // for now still assume it's an integer
    }

    fn load_view_update(&mut self, replay: &mut dyn ReplaySession) -> Result<FlowViewUpdate, Box<dyn Error>> {
        // let start_step_id = StepId(self.location.rr_ticks.0);
        // db.calls[call_key].step_id;
        // let mut path_buf = &PathBuf::from(&self.location.path);
        let mut iter_step_id = StepId(self.location.rr_ticks.0);

        // later location updated after move to first step!
        let mut flow_view_update = FlowViewUpdate::new(self.location.clone());

        let mut step_count = 0;
        let mut before_first_move = true;
        // let tracked_call_key_result = self.call_key_from(&self.location);
        let mut tracked_call_key = NO_KEY;

        // Stall detection for forward-only (non-materialized / MCR streaming)
        // replay. Materialized traces delimit the active call via `call_key`
        // changes; MCR locations carry only a frame-depth call key, and a
        // line-granularity `Step{Next}` over a function's epilogue (the
        // closing `}` / return sequence) can single-step many instructions
        // that all map to the SAME source line and SAME call depth before the
        // function actually returns. Without a stall guard the flow walker
        // re-issues `Step{Next}` up to STEP_COUNT_LIMIT (10000) times on that
        // one line, which makes `ct/load-flow` take far longer than the DAP
        // client's flow-event timeout. When the same (line, call_key) repeats
        // for `MAX_NONPROGRESSING_STEPS` consecutive steps we treat the
        // function body as exhausted and finish the flow — the values for
        // every distinct source line in the call have already been captured.
        const MAX_NONPROGRESSING_STEPS: i64 = 8;
        let mut last_seen_line: i64 = -1;
        let mut nonprogressing_steps: i64 = 0;
        // match tracked_call_key_result {
        //     Ok(call_key) => {
        //         tracked_call_key = call_key;
        //     }
        //     Err(e) => {
        //         error!("call key parse error: {e:?}");
        //         return Err(e);
        //     }
        // }

        info!("flow loop:");
        loop {
            // let (step_id, progressing) = if first {
            //     first = false;
            //     self.find_first_step(iter_step_id, replay)
            // } else {
            //     self.find_next_step(iter_step_id, replay)
            // };
            let (step_id, progressing, move_error) = if before_first_move {
                before_first_move = false;
                self.move_to_first_step(iter_step_id, replay)?
            } else {
                self.move_to_next_step(iter_step_id, replay)
            };

            if move_error {
                info!("move error: break flow");
                break;
            }

            iter_step_id = step_id;
            let mut expr_loader = ExprLoader::new(CoreTrace::default());
            let new_location = replay.load_location(&mut expr_loader)?;
            if step_count == 0 {
                self.location = new_location.clone();
                tracked_call_key = self.call_key_from(&new_location)?;
                flow_view_update.location = self.location.clone();
            }

            info!(
                "  location for step count {}: {}:{}",
                step_count, new_location.path, new_location.line
            );

            // Forward-only stall guard (see MAX_NONPROGRESSING_STEPS above).
            // Only applies to non-materialized traces; materialized traces
            // already terminate precisely via call_key changes.
            if self.trace_kind != TraceKind::Materialized && self.mode == FlowMode::Call {
                if new_location.line == last_seen_line {
                    nonprogressing_steps += 1;
                    if nonprogressing_steps >= MAX_NONPROGRESSING_STEPS {
                        info!(
                            "  flow: line {} repeated {} times without progress — finishing flow",
                            new_location.line, nonprogressing_steps
                        );
                        break;
                    }
                } else {
                    nonprogressing_steps = 0;
                    last_seen_line = new_location.line;
                }
            }

            let new_call_key = match self.call_key_from(&new_location) {
                Ok(call_key) => call_key,
                Err(e) => {
                    error!("error when parsing call key: stopping flow preload: {e:?}");
                    break;
                }
            };

            if self.mode == FlowMode::Call && tracked_call_key != new_call_key || !progressing {
                let mut load_return_value = false;

                // for now return value loading not working well for RR!
                //   should be fixed/improved in ct-native-replay
                if self.trace_kind == TraceKind::Materialized {
                    replay.step(Action::StepIn, false)?; // hopefully go back to the end of our original function
                    let return_location = replay.load_location(&mut expr_loader)?;
                    // maybe this can be improved with a limited loop/jump to return/exit of call in the future
                    if let Ok(return_call_key) = self.call_key_from(&return_location)
                        && return_call_key == tracked_call_key
                    {
                        flow_view_update = self.add_return_value(flow_view_update, replay);
                        load_return_value = true;
                    }
                }
                if !load_return_value {
                    warn!("we can't load return value");
                }
                if tracked_call_key != new_call_key {
                    info!(
                        "  a different call key now: tracked is: {:?} new is: {:?}",
                        tracked_call_key, new_call_key
                    );
                }
                if !progressing {
                    info!("  not progressing in stepping anymore");
                }
                info!("  break flow!");
                break;
            }

            if step_count >= STEP_COUNT_LIMIT as i64 {
                info!("  break flow because of step count limit");
                break;
            }

            let events = self.load_step_flow_events(replay, step_id);
            // for now not sending last step id for line visit
            // but this flow step object *can* contain info about several actual steps
            // e.g. events from some of the next steps on the same line visit
            // one can analyze the step id of the next step, or we can add this info to the object
            let line = new_location.line;
            flow_view_update.steps.push(FlowStep::new(
                line,
                step_count,
                replay.current_step_id(),
                Iteration(0),
                LoopId(0),
                events,
            ));
            flow_view_update.relevant_step_count.push(line as usize);
            flow_view_update.add_step_count(line, step_count);
            info!("  process loops");
            let path_buf = &PathBuf::from(&new_location.path);
            flow_view_update = self.process_loops(
                flow_view_update.clone(),
                Position(new_location.line),
                replay.current_step_id(),
                path_buf,
                step_count,
            );
            flow_view_update = self.log_expressions(
                flow_view_update.clone(),
                Position(new_location.line),
                replay,
                step_id,
                &new_location,
            );
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
        Ok(flow_view_update)
    }

    #[allow(clippy::unwrap_used)]
    fn process_loops(
        &mut self,
        mut flow_view_update: FlowViewUpdate,
        line: Position,
        step_id: StepId,
        path_buf: &PathBuf,
        step_count: i64,
    ) -> FlowViewUpdate {
        if let Some(loop_shape) = self.flow_preloader.expr_loader.get_loop_shape(line, path_buf) {
            info!("  loop shape {:?}", loop_shape);
            if loop_shape.first.0 == line.0 && !self.active_loops.contains(&loop_shape.first) {
                flow_view_update.loops.push(Loop {
                    base: LoopId(loop_shape.loop_id.0),
                    base_iteration: Iteration(0),
                    internal: vec![],
                    first: loop_shape.first,
                    last: loop_shape.last,
                    registered_line: loop_shape.first,
                    iteration: Iteration(0),
                    step_counts: vec![StepCount(step_count)],
                    rr_ticks_for_iterations: vec![RRTicks(step_id.0)],
                });
                self.active_loops.push(loop_shape.first);
                flow_view_update
                    .loop_iteration_steps
                    .push(vec![LoopIterationSteps::default()]);
                flow_view_update.branches_taken.push(vec![BranchesTaken::default()]);
                info!("    add an active loop");
            } else if (flow_view_update.loops.last().unwrap().first.0) == line.0 {
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
                    .push(RRTicks(step_id.0));
                info!("    add iteration");
            }
        }

        if flow_view_update.loops.last().unwrap().first.0 <= line.0
            && flow_view_update.loops.last().unwrap().last.0 >= line.0
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
                    .insert(line.0 as usize, step_count as usize);
                flow_view_update.add_branches(
                    flow_view_update.loops.clone().last_mut().unwrap().base.0,
                    self.flow_preloader.expr_loader.load_branch_for_position(line, path_buf),
                );
                info!("    add branch for position {:?} {:?}", path_buf.display(), line);
            }
        } else {
            flow_view_update.loop_iteration_steps[0][0]
                .table
                .insert(line.0 as usize, step_count as usize);
            flow_view_update.add_branches(
                0,
                self.flow_preloader.expr_loader.load_branch_for_position(line, path_buf),
            );
            info!("    add branch for position {:?} {:?}", path_buf.display(), line);
        }
        info!("    branches taken {:?}", flow_view_update.branches_taken);
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

    fn load_step_flow_events(&self, replay: &mut dyn ReplaySession, step_id: StepId) -> Vec<FlowEvent> {
        // load not only exactly this step, but for the whole step line "visit":
        // include events for next steps for this visit, because we don't process those steps in flow
        // otherwise, but we do something like a `next`
        let exact = false;
        let step_events = replay.load_step_events(step_id, exact);
        let flow_events = step_events.iter().map(|event| self.to_flow_event(event)).collect();
        // info!("flow events: {flow_events:?}");
        #[allow(clippy::let_and_return)] // useful to have the variable for debugging/logging
        flow_events
    }

    #[allow(clippy::unwrap_used)]
    fn log_expressions(
        &mut self,
        mut flow_view_update: FlowViewUpdate,
        line: Position,
        replay: &mut dyn ReplaySession,
        step_id: StepId,
        location: &Location,
    ) -> FlowViewUpdate {
        let mut expr_order: Vec<String> = vec![];
        let mut variable_map: HashMap<String, Value> = HashMap::default();

        // for value_record in &db.variables[step_id] {
        //     variable_map.insert(
        //         db.variable_names[value_record.variable_id].clone(),
        //         value_record.clone(),
        //     );
        // }

        // for (variable_id, place) in &db.variable_cells[step_id] {
        //     let value_record = db.load_value_for_place(*place, step_id);
        //     let full_value_record = FullValueRecord {
        //         variable_id: *variable_id,
        //         value: value_record,
        //     };
        //     let name = db.variable_name(*variable_id);
        //     variable_map.insert(name.clone(), full_value_record);
        // }

        if let Some(var_list) = self.flow_preloader.get_var_list(line, location) {
            info!("  log expressions: {:?}", var_list.clone());
            for value_name in &var_list {
                // Try loading the value with the original name first
                let value_result = replay.load_value(value_name, Some(LOAD_FLOW_VALUE_RR_DEPTH_LIMIT), self.lang);

                // Check if we need to try alternate names (either error or "not found" value)
                let needs_alternate_names = self.lang == Lang::Nim
                    && match &value_result {
                        Err(_) => true,
                        Ok(v) => v.is_not_found(),
                    };

                // For Nim, try alternate naming strategies if the original name fails
                let final_value = if needs_alternate_names {
                    let mut found_value = None;

                    // Strategy 1: Try _pN suffixes for parameters (Nim 2.x uses _p0, _p1, etc.)
                    for suffix in 0..=5 {
                        let param_name = format!("{}_p{}", value_name, suffix);
                        if let Ok(value) =
                            replay.load_value(&param_name, Some(LOAD_FLOW_VALUE_RR_DEPTH_LIMIT), self.lang)
                            && !value.is_not_found()
                        {
                            info!(
                                "    found Nim param via suffixed name: {} -> {}",
                                value_name, param_name
                            );
                            found_value = Some(value);
                            break;
                        }
                    }

                    // Strategy 2: Try _N suffixes for local variables (Nim 2.2+ uses _1, _2, etc.)
                    if found_value.is_none() {
                        for suffix in 1..=5 {
                            let suffixed_name = format!("{}_{}", value_name, suffix);
                            if let Ok(value) =
                                replay.load_value(&suffixed_name, Some(LOAD_FLOW_VALUE_RR_DEPTH_LIMIT), self.lang)
                                && !value.is_not_found()
                            {
                                info!(
                                    "    found Nim local via suffixed name: {} -> {}",
                                    value_name, suffixed_name
                                );
                                found_value = Some(value);
                                break;
                            }
                        }
                    }

                    // Strategy 3: Try mangled names for global variables (module-level)
                    // Uses both Nim 1.6 (ROT13) and Nim 2.x (direct) styles
                    if found_value.is_none() {
                        let path = Path::new(&location.path);
                        if let Some(mut iter) = nim_mangling::MangledNameDualIterator::new(value_name, path, 20) {
                            while let Some(mangled_name) = iter.next_candidate() {
                                if let Ok(value) =
                                    replay.load_value(mangled_name, Some(LOAD_FLOW_VALUE_RR_DEPTH_LIMIT), self.lang)
                                    && !value.is_not_found()
                                {
                                    // Copy name only on success (to release borrow before calling iter methods)
                                    let matched_name = mangled_name.to_string();
                                    info!(
                                        "    found Nim global via mangled name: {} -> {} (style: {:?})",
                                        value_name,
                                        matched_name,
                                        iter.current_style()
                                    );
                                    // Record successful style for future lookups
                                    iter.record_success();
                                    found_value = Some(value);
                                    break;
                                }
                            }
                        }
                    }

                    found_value.ok_or_else(|| -> Box<dyn Error> { "not found".into() })
                } else {
                    value_result
                };

                if let Ok(value) = final_value {
                    // if variable_map.contains_key(value_name) {
                    let ct_value = to_ct_value(&value);
                    flow_view_update
                        .steps
                        .last_mut()
                        .unwrap()
                        .before_values
                        .insert(value_name.clone(), ct_value.clone());
                    info!("    insert in variables_map {}", value_name);
                    variable_map.insert(value_name.clone(), ct_value);
                }
                expr_order.push(value_name.clone());
            }

            flow_view_update.steps.last_mut().unwrap().expr_order = expr_order.clone();
        } else {
            // Fallback: when tree-sitter has no grammar for this language (e.g. Cairo,
            // Circom, Leo, Tolk, MASM), load variable names directly from the trace data.
            // DB-based traces embed variable names at each step, so we can use load_locals()
            // instead of the static source analysis.
            info!(
                " no tree-sitter var list for line {:?} at step {:?} — trying trace-embedded variables",
                line, step_id
            );
            if let Ok(locals) = replay.load_locals(CtLoadLocalsArguments {
                rr_ticks: 0,
                count_budget: 100,
                min_count_limit: 0,
                lang: self.lang,
                watch_expressions: vec![],
                depth_limit: -1, // NO_DEPTH_LIMIT
            }) {
                for local in &locals {
                    let value_name = local.expression.clone();
                    let ct_value = to_ct_value(&local.value);
                    flow_view_update
                        .steps
                        .last_mut()
                        .unwrap()
                        .before_values
                        .insert(value_name.clone(), ct_value.clone());
                    variable_map.insert(value_name.clone(), ct_value);
                    expr_order.push(value_name);
                }
                flow_view_update.steps.last_mut().unwrap().expr_order = expr_order.clone();
                info!(
                    " loaded {} variables from trace data at step {:?}",
                    locals.len(),
                    step_id
                );
            }
        }

        if self.last_step_id.0 >= 0 && flow_view_update.steps.len() >= 2 {
            let index = flow_view_update.steps.len() - 2;

            for variable in &self.last_expr_order {
                if variable_map.contains_key(variable) {
                    flow_view_update.steps[index]
                        .after_values
                        .insert(variable.clone(), variable_map[variable].clone());
                }
            }
        }

        self.last_step_id = step_id;
        self.last_expr_order = expr_order;
        flow_view_update
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task::{
        Breakpoint, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg, ProgramEvent,
        VariableWithRecord,
    };
    use crate::value::ValueRecordWithType;

    #[derive(Debug)]
    struct MockReplay {
        calls: Vec<String>,
        current_location: Location,
        call_entry_location: Location,
        current_step_id: StepId,
    }

    impl MockReplay {
        fn new(current_location: Location, call_entry_location: Location) -> Self {
            Self {
                current_step_id: StepId(current_location.rr_ticks.0),
                current_location,
                call_entry_location,
                calls: vec![],
            }
        }
    }

    impl ReplaySession for MockReplay {
        fn load_location(&mut self, _expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
            self.calls.push("load_location".to_string());
            Ok(self.current_location.clone())
        }

        fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
            unimplemented!()
        }

        fn load_events(&mut self) -> Result<Events, Box<dyn Error>> {
            unimplemented!()
        }

        fn step(&mut self, _action: Action, _forward: bool) -> Result<bool, Box<dyn Error>> {
            unimplemented!()
        }

        fn load_locals(&mut self, _arg: CtLoadLocalsArguments) -> Result<Vec<VariableWithRecord>, Box<dyn Error>> {
            unimplemented!()
        }

        fn load_value(
            &mut self,
            _expression: &str,
            _depth_limit: Option<usize>,
            _lang: Lang,
        ) -> Result<ValueRecordWithType, Box<dyn Error>> {
            unimplemented!()
        }

        fn load_return_value(
            &mut self,
            _depth_limit: Option<usize>,
            _lang: Lang,
        ) -> Result<ValueRecordWithType, Box<dyn Error>> {
            unimplemented!()
        }

        fn load_step_events(&mut self, _step_id: StepId, _exact: bool) -> Vec<DbRecordEvent> {
            unimplemented!()
        }

        fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn Error>> {
            unimplemented!()
        }

        fn load_history(
            &mut self,
            _arg: &LoadHistoryArg,
        ) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>> {
            unimplemented!()
        }

        fn add_breakpoint(
            &mut self,
            _path: &str,
            _line: i64,
            _column: Option<i64>,
            _condition: Option<String>,
        ) -> Result<Breakpoint, Box<dyn Error>> {
            unimplemented!()
        }

        fn delete_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>> {
            unimplemented!()
        }

        fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>> {
            unimplemented!()
        }

        fn toggle_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn Error>> {
            unimplemented!()
        }

        fn enable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
            unimplemented!()
        }

        fn disable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
            unimplemented!()
        }

        fn jump_to(&mut self, step_id: StepId) -> Result<bool, Box<dyn Error>> {
            self.calls.push(format!("jump_to:{}", step_id.0));
            self.current_step_id = step_id;
            Ok(true)
        }

        fn jump_to_call(&mut self, location: &Location) -> Result<Location, Box<dyn Error>> {
            self.calls.push(format!("jump_to_call:{}", location.rr_ticks.0));
            self.current_step_id = StepId(self.call_entry_location.rr_ticks.0);
            Ok(self.call_entry_location.clone())
        }

        fn event_jump(&mut self, _event: &ProgramEvent) -> Result<bool, Box<dyn Error>> {
            unimplemented!()
        }

        fn callstack_jump(&mut self, _depth: usize) -> Result<(), Box<dyn Error>> {
            unimplemented!()
        }

        fn location_jump(&mut self, location: &Location) -> Result<(), Box<dyn Error>> {
            self.calls.push(format!("location_jump:{}", location.rr_ticks.0));
            self.current_step_id = StepId(location.rr_ticks.0);
            Ok(())
        }

        fn tracepoint_jump(&mut self, _event: &ProgramEvent) -> Result<(), Box<dyn Error>> {
            unimplemented!()
        }

        fn evaluate_call_expression(
            &mut self,
            _call_expression: &str,
            _lang: Lang,
        ) -> Result<ValueRecordWithType, Box<dyn Error>> {
            unimplemented!()
        }

        fn current_step_id(&mut self) -> StepId {
            self.current_step_id
        }

        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    fn make_location(line: i64, rr_ticks: i64, event: i64) -> Location {
        Location {
            path: "example.py".to_string(),
            line,
            rr_ticks: RRTicks(rr_ticks),
            event,
            ..Location::default()
        }
    }

    #[test]
    fn materialized_call_body_entry_guard_accepts_real_tick_zero_source_locations() {
        assert!(should_enter_materialized_call_body(&make_location(1, 0, 0)));
        assert!(should_enter_materialized_call_body(&make_location(-1, 42, 0)));
        assert!(!should_enter_materialized_call_body(&make_location(-1, 0, 0)));
        assert!(!should_enter_materialized_call_body(&make_location(0, 0, 0)));
    }

    #[test]
    fn db_call_flow_starts_from_exact_step_when_step_id_is_nonzero() {
        // When step_id is non-zero the caller already has an exact step
        // (e.g. from a DAP breakpoint hit). We should jump directly to that
        // step without rewinding via jump_to_call — otherwise we would land
        // at the enclosing function entry and produce flow data for the wrong
        // loop iteration / call instance.
        let flow_preloader = FlowPreloader::new();
        let request_location = make_location(15, 42, 0);
        let current_location = request_location.clone();
        let call_entry_location = make_location(10, 17, 0);
        let mut replay = MockReplay::new(current_location, call_entry_location);
        let preloader = CallFlowPreloader::new(
            &flow_preloader,
            request_location,
            HashSet::new(),
            HashSet::new(),
            FlowMode::Call,
            TraceKind::Materialized,
        );

        let Ok((step_id, progressing, move_error)) = preloader.move_to_first_step(StepId(42), &mut replay) else {
            todo!()
        };

        assert_eq!(step_id, StepId(42));
        assert!(progressing);
        assert!(!move_error);
        assert_eq!(replay.calls, vec!["jump_to:42"]);
    }

    #[test]
    fn rr_call_flow_starts_from_enclosing_call_entry_after_location_seek() {
        let flow_preloader = FlowPreloader::new();
        let request_location = make_location(21, 84, 7);
        let current_location = request_location.clone();
        let call_entry_location = make_location(19, 64, 7);
        let mut replay = MockReplay::new(current_location, call_entry_location);
        let preloader = CallFlowPreloader::new(
            &flow_preloader,
            request_location,
            HashSet::new(),
            HashSet::new(),
            FlowMode::Call,
            TraceKind::Recreator,
        );

        let Ok((step_id, progressing, move_error)) = preloader.move_to_first_step(StepId(84), &mut replay) else {
            todo!()
        };

        assert_eq!(step_id, StepId(64));
        assert!(progressing);
        assert!(!move_error);
        assert_eq!(
            replay.calls,
            vec!["location_jump:84", "load_location", "jump_to_call:84"]
        );
    }
}
