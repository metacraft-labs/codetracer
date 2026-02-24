use std::error::Error;

// use log::info;
use codetracer_trace_types::{CallKey, StepId, NO_KEY};

use crate::db::{Db, DbCall, EndOfProgram};
use crate::distinct_vec::DistinctVec;
use crate::expr_loader::ExprLoader;
use crate::task::{
    CallLine, CallLineContentKind, CallLineMetadata, CalltraceNonExpandedKind, GlobalCallLineIndex, NO_DEPTH, NO_INDEX,
};

#[derive(Debug, Clone)]
pub struct Calltrace {
    // pub db: &'a Db,
    // for now simpler instead of ref/lifetimes
    // to clone all calls at first: TODO
    // if a bottleneck?
    calls: DistinctVec<CallKey, DbCall>,
    max_depth: usize,
    pub depth_offset: usize,
    pub call_states: DistinctVec<CallKey, CallState>,
    pub global_call_lines: DistinctVec<GlobalCallLineIndex, CallLineMetadata>,
    pub start_call_key: CallKey,
    pub optimize_collapse: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct CallState {
    // pub key: CallKey,
    pub expanded: bool,
    pub non_expanded_kind: CalltraceNonExpandedKind,
    pub hidden_children: bool,
    pub children_count: usize,
}

impl Calltrace {
    pub fn new(db: &Db) -> Self {
        let mut call_states = DistinctVec::new();
        for call_key_int in 0..db.calls.len() {
            let call_key = CallKey(call_key_int as i64);
            call_states.push(CallState {
                expanded: false,
                hidden_children: false,
                non_expanded_kind: CalltraceNonExpandedKind::Calls,
                children_count: db.calls[call_key].children_keys.len(),
            });
        }
        let calls = db.calls.clone();
        let global_call_lines = DistinctVec::new();

        Calltrace {
            calls,
            max_depth: 0,
            depth_offset: 0,
            call_states,
            global_call_lines,
            // we want it to be < 0,
            // so the first actual location leads to
            // `jump_to` and building up the index
            // with calls
            start_call_key: CallKey(-1),
            optimize_collapse: false,
        }
    }

    pub fn jump_to(&mut self, step_id: StepId, auto_collapsing: bool, db: &Db) {
        self.jump_to_with_depth(step_id, auto_collapsing, None, db);
    }

    /// Jump to the call containing `step_id` and rebuild the global call-line
    /// index.
    ///
    /// When `auto_collapsing` is true the existing smart-collapse heuristic
    /// is used (collapsing siblings before the active call on each stack
    /// level).  When it is false **and** `max_depth` is provided, all calls
    /// up to `max_depth` are expanded so that the full tree is visible —
    /// this is the path taken by the Python API bridge which does not use
    /// the GUI's collapsing behaviour.
    pub fn jump_to_with_depth(&mut self, step_id: StepId, auto_collapsing: bool, max_depth: Option<usize>, db: &Db) {
        let call_key = db.call_key_for_step(step_id);
        if auto_collapsing {
            self.autocollapse_callstack(step_id, call_key, db);
        } else if let Some(depth_limit) = max_depth {
            // Expand all calls up to the requested depth so the Python API
            // (and other non-GUI callers) can see the full call tree.
            self.expand_all_up_to_depth(depth_limit, db);
        }
        self.start_call_key = call_key;
        self.rebuild_global_call_lines();
    }

    /// Mark all calls at depth <= `max_depth` as expanded so they appear
    /// in the global call-line index built by [`rebuild_global_call_lines`].
    fn expand_all_up_to_depth(&mut self, max_depth: usize, db: &Db) {
        for call_key_int in 0..self.call_states.len() {
            let call_key = CallKey(call_key_int as i64);
            let call = &db.calls[call_key];
            if call.depth <= max_depth {
                self.call_states[call_key].expanded = true;
                self.call_states[call_key].hidden_children = call.depth == max_depth;
            }
        }
    }

    pub fn change_expand_state(&mut self, call_key: CallKey, showing_children: bool) {
        self.call_states[call_key].hidden_children = !showing_children;
        self.call_states[call_key].expanded = true;
        if !showing_children {
            self.call_states[call_key].non_expanded_kind = CalltraceNonExpandedKind::Children;
        }
        let call_states_count = self.call_states.len();
        let original_depth = self.calls[call_key].depth;

        let mut call_state_key = CallKey(call_key.0 + 1);
        while (call_state_key.0 as usize) < call_states_count && self.calls[call_state_key].depth > original_depth {
            let call_state = &mut self.call_states[call_state_key];
            if showing_children {
                call_state.expanded = true;
                call_state.hidden_children = false; // TODO: what to do here?
            } else {
                // info!("hide {call_state_key:?}");
                call_state.expanded = false;
                call_state.hidden_children = true; // TODO: what to do here?
            }
            call_state_key = CallKey(call_state_key.0 + 1);
        }
        self.rebuild_global_call_lines();
    }

    pub fn calc_scroll_position(&mut self) -> usize {
        let mut position: usize = 0;
        let mut kind = CalltraceNonExpandedKind::Callstack;
        for call_state in self.call_states.iter() {
            if call_state.non_expanded_kind == CalltraceNonExpandedKind::Calls && position > 0 {
                position += 1;
                break;
            } else if call_state.non_expanded_kind == CalltraceNonExpandedKind::CallstackInternal
                && (kind != CalltraceNonExpandedKind::CallstackInternal
                    && kind != CalltraceNonExpandedKind::CallstackInternalChild)
            {
                position += 1;
            }
            kind = call_state.non_expanded_kind;
        }
        position
    }

    pub fn expand_callstack_internal(&mut self, start_count: CallKey, mut limit: i64) {
        for key in start_count.0..self.calls.len() as i64 {
            let call_key = CallKey(key);
            let call = &self.calls[call_key];
            if self.call_states[call_key].non_expanded_kind == CalltraceNonExpandedKind::CallstackInternal {
                self.call_states[call_key].non_expanded_kind = CalltraceNonExpandedKind::Calls;
                self.call_states[call_key].expanded = true;
                if !call.children_keys.is_empty() {
                    self.call_states[call_key].hidden_children = true;
                }
                limit -= 1;
            }
            if limit == 0 {
                break;
            }
        }
        self.rebuild_global_call_lines();
    }

    pub fn expand_callstack(&mut self, start_count: CallKey) {
        for key in start_count.0..self.calls.len() as i64 {
            let call_key = CallKey(key);
            if self.call_states[call_key].non_expanded_kind == CalltraceNonExpandedKind::Callstack {
                self.call_states[call_key].non_expanded_kind = CalltraceNonExpandedKind::Calls;
                self.call_states[call_key].expanded = true;
            }
        }
        self.rebuild_global_call_lines();
    }

    pub fn change_non_expanded_kind(&mut self, call_key: CallKey, kind: CalltraceNonExpandedKind) {
        for key in 0..call_key.0 {
            self.call_states[CallKey(key)].non_expanded_kind = kind;
            self.call_states[CallKey(key)].expanded = true;
        }
        self.rebuild_global_call_lines();
    }

    fn rebuild_global_call_lines(&mut self) {
        let mut global_call_line_index = GlobalCallLineIndex(0);
        let mut callstack_count: usize = 0;
        let mut start_callstack_count: usize = 0;
        let mut callstack_key = NO_INDEX;
        let mut callstack_depth = NO_DEPTH;
        self.global_call_lines.clear();
        for (call_key_int, call_state) in self.call_states.iter().enumerate() {
            let call_key = CallKey(call_key_int as i64);
            // reset on each build: children must have bigger keys,
            // so they increasing it should happen after this reset
            // in the loop
            let call = &self.calls[call_key];

            // info!("call line?: {call_key_int:?} {call_state:?}");
            if call_state.expanded {
                if start_callstack_count > 0 {
                    let metadata = CallLineMetadata::callstack_count(
                        CallKey(callstack_key),
                        start_callstack_count,
                        call.depth,
                        global_call_line_index,
                        CallLineContentKind::StartCallstackCount,
                    );
                    self.global_call_lines.push(metadata);
                    global_call_line_index += 1;
                    start_callstack_count = 0;
                    callstack_key = NO_INDEX;
                    callstack_depth = NO_DEPTH;
                } else if callstack_count == 1 && self.optimize_collapse {
                    let key = CallKey(callstack_key);
                    let state = self.call_states[key];
                    let metadata = CallLineMetadata::call(
                        key,
                        state.children_count,
                        state.hidden_children,
                        callstack_depth,
                        global_call_line_index,
                    );
                    self.global_call_lines.push(metadata);
                    global_call_line_index += 1;
                    callstack_count = 0;
                    callstack_key = NO_INDEX;
                    callstack_depth = NO_DEPTH;
                } else if callstack_count > 0 {
                    let metadata = CallLineMetadata::callstack_count(
                        CallKey(callstack_key),
                        callstack_count,
                        callstack_depth,
                        global_call_line_index,
                        CallLineContentKind::CallstackInternalCount,
                    );
                    self.global_call_lines.push(metadata);
                    global_call_line_index += 1;
                    callstack_count = 0;
                    callstack_key = NO_INDEX;
                    callstack_depth = NO_DEPTH;
                }

                let metadata = CallLineMetadata::call(
                    call_key,
                    call_state.children_count,
                    call_state.hidden_children,
                    call.depth,
                    global_call_line_index,
                );
                self.global_call_lines.push(metadata);
                global_call_line_index += 1;
            } else if call_state.non_expanded_kind == CalltraceNonExpandedKind::Callstack && !call_state.expanded {
                start_callstack_count += 1;
                if callstack_key == NO_INDEX {
                    callstack_key = call_key.0;
                }
            } else if call_state.non_expanded_kind == CalltraceNonExpandedKind::CallstackInternal
                && start_callstack_count == 0
            {
                callstack_count += 1;
                if callstack_key == NO_INDEX {
                    callstack_key = call_key.0;
                    callstack_depth = call.depth;
                }
            }
        }
        self.global_call_lines
            .push(CallLineMetadata::end_of_program_call(global_call_line_index));
    }

    // TODO:
    // collapse -> collapse call arg and depending on kind, his siblings or children or only it
    // expand -> expand call arg and depending on kind, his siblings or children or all before it(expand all: callstack)
    // after those: rebuild index
    // filter?
    //   -> depth > x only, collapse those with those and rebuild
    //   -> pattern: collapse only those matching it and their children for now
    //
    // test:
    //   just simple calltrace
    //   autocollapsing?
    //   visible(?)
    //   loading lines n
    //   collapse x/expand x
    //   filter?
    //   (property: calltrace valid and matching what is happening?)
    fn autocollapse_callstack(&mut self, step_id: StepId, current_call_key: CallKey, db: &Db) {
        // autocollapse siblings before the current call
        // on each level of the callstack
        // potentially also part of the callstack itself
        // if it's too long
        // TODO
        let callstack = self.load_callstack(step_id, db);

        // callstack originally is in opposite order of depth
        //   compared to call state/calltrace iteration:
        // from deeper to more shallow!
        let callstack_level_keys: Vec<CallKey> = callstack
            .iter()
            .rev()
            .map(|call| callstack[callstack.len() - 1 - call.depth].key)
            .collect();

        for (call_key_int, call_state) in self.call_states.iter_mut().enumerate() {
            let call_key = CallKey(call_key_int as i64);
            let call = &db.calls[call_key];
            let current_call = &db.calls[current_call_key];

            if call.depth < callstack_level_keys.len() {
                let callstack_level_key = callstack_level_keys[call.depth];
                // info!("autocollapse? {call:?} {call_key:?} {callstack_level_key:?}");
                if call_key.0 < callstack_level_key.0 && call.depth <= self.max_depth + 1 {
                    call_state.expanded = false;
                    call_state.non_expanded_kind = CalltraceNonExpandedKind::CallstackInternal;
                } else if call_key.0 < callstack_level_key.0 && call.depth > self.max_depth + 1 {
                    call_state.expanded = false;
                    call_state.non_expanded_kind = CalltraceNonExpandedKind::CallstackInternalChild;
                } else {
                    // call_state.expanded = true;
                    let check_depth: i32 = current_call.depth as i32 - 5;
                    if (call.depth as i32) < check_depth
                        && call_key != current_call_key
                        && call_key.0 == callstack_level_key.0
                    {
                        call_state.expanded = false;
                        call_state.non_expanded_kind = CalltraceNonExpandedKind::Callstack;
                    } else {
                        call_state.expanded = true;
                        call_state.non_expanded_kind = CalltraceNonExpandedKind::Calls;
                        self.depth_offset = call.depth
                    }
                    self.max_depth = call.depth;
                }
            } else if call_key.0 < current_call_key.0 {
                call_state.non_expanded_kind = CalltraceNonExpandedKind::CallstackInternalChild;
                call_state.expanded = false;
            } else {
                // info!("autocollapse? {call:?} depth big: expanded");
                call_state.expanded = true;
                // call_state.non_expanded_kind = CalltraceNonExpandedKind::Calls;
            }
        }

        // unimplemented!()
    }

    pub fn load_callstack(&self, step_id: StepId, db: &Db) -> Vec<DbCall> {
        let mut callstack = vec![];
        if step_id.0 < db.steps.len().try_into().unwrap_or(i64::MAX) {
            let current_step = &db.steps[step_id];
            let mut call_key = current_step.call_key;

            assert!(call_key.0 >= 0);

            // info!("step {:#?}", current_step);
            while call_key != NO_KEY {
                let call_record = &db.calls[call_key];
                callstack.push(call_record.clone());

                call_key = call_record.parent_key;
            }
        }

        callstack
    }

    pub fn load_lines(
        &self,
        from: GlobalCallLineIndex,
        count: usize,
        db: &Db,
        expr_loader: &mut ExprLoader,
    ) -> Result<Vec<CallLine>, Box<dyn Error>> {
        let mut results = vec![];
        let mut index = from;
        while results.len() < count && index.0 < self.global_call_lines.len() {
            let metadata = &self.global_call_lines[index];
            results.push(self.to_call_line(metadata, db, expr_loader));
            index += 1;
        }
        // info!("{:?}", results);
        Ok(results)
    }

    fn to_call_line(&self, metadata: &CallLineMetadata, db: &Db, expr_loader: &mut ExprLoader) -> CallLine {
        if metadata.content.kind == CallLineContentKind::Call {
            let call = db.to_call(&self.calls[metadata.content.call_key], expr_loader);
            CallLine::call(
                call,
                metadata.content.hidden_children,
                metadata.content.children_count,
                metadata.depth,
            )
        } else if metadata.content.kind == CallLineContentKind::CallstackInternalCount {
            let call = db.to_call(&self.calls[metadata.content.call_key], expr_loader);
            CallLine::callstack_count(
                metadata.content.non_expanded_kind,
                call,
                metadata.content.count,
                metadata.depth,
            )
        } else if metadata.content.kind == CallLineContentKind::StartCallstackCount {
            let call = db.to_call(&self.calls[CallKey(0)], expr_loader);
            CallLine::start_callstack_count(
                metadata.content.non_expanded_kind,
                call,
                metadata.content.count,
                metadata.depth,
            )
        } else if metadata.content.kind == CallLineContentKind::EndOfProgramCall {
            let (is_error, text) = if let EndOfProgram::Error { reason } = &db.end_of_program {
                (true, format!("<{reason}>"))
            } else {
                (false, "<end of program>".to_string())
            };
            CallLine::end_of_program_call(
                metadata.content.non_expanded_kind,
                is_error,
                &text,
                // IMPORTANT:
                // for now, we accept end of program error events only for the last step
                // if this assumption changes, we need to update this as well, or to
                // pass the step id with the end_of_program object!
                StepId((db.steps.len() - 1) as i64),
            )
        } else {
            let call = db.to_call(&self.calls[metadata.content.call_key], expr_loader);
            CallLine::non_expanded(
                metadata.content.non_expanded_kind,
                call,
                metadata.content.count,
                metadata.depth,
            )
        }
    }

    // let results =
    // let call_key = from;
    // while call_key
    //         let mut non_expanded_count = 0;
    //         let mut non_expanded_kind = CalltraceNonExpandedKind::Calls;
    //         let mut non_expanded_depth = 0;
    //         let mut index = from;
    //             if call_key.0 >= self.calls.len() as i64 || call_key.0 < 0 {
    //             break;
    //         }
    //         let call_state = self.call_states[call_key];
    //         let call = &self.calls[call_key];
    //         if call_state.expanded {
    //             if non_expanded_count > 0 {
    //                 results.push(CallLine::non_expanded(
    //                     non_expanded_kind,
    //                     non_expanded_count,
    //                     non_expanded_depth));
    //             }
    //             non_expanded_count = 0;
    //             non_expanded_kind = CalltraceNonExpandedKind::Calls;
    //             non_expanded_depth = 0;

    //             results.push(CallLine::call(db.to_call(&call), call.depth));
    //         } else {
    //             non_expanded_count += 1;
    //             if non_expanded_count == 1 {
    //                 // first: take kind/depth
    //                 non_expanded_kind = call_state.non_expanded_kind;
    //                 non_expanded_depth = call.depth;
    //             }
    //         }

    //         call_key += 1;
    //     }
    //     Ok(results)
    // }
}
