use std::cmp::{max, min};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;

use codetracer_trace_types::{CallKey, StepId};
use log::info;

use crate::db::{DbStep, MaterializedReplaySession};
use crate::distinct_vec::DistinctVec;
use crate::expr_loader::ExprLoader;
use crate::flow_preloader::FlowPreloader;
use crate::task::{FlowMode, LineStep, LineStepKind, LineStepValue, Location, TraceKind};
use crate::trace_reader::TraceReader;

#[derive(Debug, Clone)]
pub struct StepLinesLoader {
    pub global_line_steps: DistinctVec<StepId, Option<LineStep>>,
    flow_loaded: HashSet<i64>,
}

impl StepLinesLoader {
    #[allow(clippy::expect_used)]
    pub fn new(reader: &dyn TraceReader, expr_loader: &mut ExprLoader) -> Self {
        let mut global_line_steps = DistinctVec::new();
        for step_id_int in 0..reader.step_count() {
            let step_id = StepId(step_id_int as i64);
            let line_step = reader
                .step(step_id)
                .map(|step| Self::simple_line_step(step_id, *step, reader, expr_loader));
            global_line_steps.push(line_step);
        }
        StepLinesLoader {
            global_line_steps,
            flow_loaded: HashSet::new(),
        }
    }

    fn simple_line_step(
        step_id: StepId,
        step: DbStep,
        reader: &dyn TraceReader,
        expr_loader: &mut ExprLoader,
    ) -> LineStep {
        // let mut expr_loader = ExprLoader::new();
        let line = step.line;
        let raw_path = format!(
            "{}",
            reader.workdir().join(reader.path(step.path_id).unwrap_or("")).display()
        );
        let path = PathBuf::from(&raw_path);
        let source_line = if let Ok(()) = expr_loader.load_file(&path) {
            expr_loader.get_source_line(&path, line.0 as usize)
        } else {
            "<not readable>".to_string()
        };
        LineStep {
            kind: LineStepKind::Line,
            // used with different meaning! absolute,
            // because it's a global list
            // when preparing for client, replace for now with a relative one
            // as we are compatible with the rr/gdb backend
            // no virtualization for now for this
            delta: step_id.0,

            location: reader.load_location(step_id, CallKey(-1), expr_loader),
            source_line,
            // TODO? iteration_info: vec![],
            values: vec![],
        }
    }
    pub fn load_lines(
        &mut self,
        location: &Location,
        backward_count: usize,
        forward_count: usize,
        reader: Arc<dyn TraceReader>,
        flow_preloader: &mut FlowPreloader,
    ) -> Vec<LineStep> {
        let mut line_steps = vec![];
        let location_step_index = location.rr_ticks.0;

        // ensure `start_index` >= 0
        let start_index: usize = max(location_step_index - backward_count as i64, 0i64) as usize;

        // ensure `min_sum` >= 0 => `until_index` >= 0 if rr_ticks hypothetically is a very negative number
        let until_sum: usize = max(location_step_index + forward_count as i64, 0i64) as usize;
        let until_index: usize = min(until_sum, self.global_line_steps.len());

        let mut last_callstack_depth = location.callstack_depth;
        let mut last_function_name = location.function_name.clone();

        for step_id_int in start_index..until_index {
            if step_id_int >= self.global_line_steps.len() {
                break;
            }
            let step_id = StepId(step_id_int as i64);
            if self.global_line_steps[step_id].is_none() {
                continue;
            }
            let call_key = reader.call_key_for_step(step_id).unwrap_or(CallKey(-1));
            if !self.flow_loaded.contains(&call_key.0) {
                let Some(line_step) = self.global_line_steps[step_id].as_ref() else {
                    continue;
                };
                let location = line_step.location.clone();
                let mut replay = MaterializedReplaySession::new(Arc::clone(&reader));
                let flow_update = flow_preloader.load(location, FlowMode::Call, TraceKind::Materialized, &mut replay);
                if !flow_update.error && !flow_update.view_updates.is_empty() {
                    let flow_view_update = &flow_update.view_updates[0];
                    for flow_step in flow_view_update.steps.iter() {
                        let flow_values: Vec<LineStepValue> = flow_step
                            .before_values
                            .iter()
                            .map(|(expression, value)| LineStepValue {
                                expression: expression.clone(),
                                value: value.clone(),
                            })
                            .collect();
                        if let Some(Some(line_step)) = self.global_line_steps.get_mut(StepId(flow_step.rr_ticks.0)) {
                            line_step.values = flow_values;
                        }
                    }
                    self.flow_loaded.insert(call_key.0);
                }
            }
            if step_id_int < self.global_line_steps.len() {
                let Some(mut line_step) = self.global_line_steps[step_id].clone() else {
                    continue;
                };
                // should be
                //   negative for step_id < location_step_index: (backwards)
                //   positive for step_id >= location_step_index: (forwards)
                line_step.delta = step_id_int as i64 - location_step_index;

                info!(
                    "new and last {} {}",
                    line_step.location.callstack_depth, last_callstack_depth
                );
                // TODO: potentially we can do it even in a simpler way, just by checking
                // calls on those steps, and call_key
                // but this was closer to the rr/gdb impl
                if line_step.location.callstack_depth != last_callstack_depth {
                    let event_line_step =
                        self.load_call_or_return_line_step(&line_step, last_callstack_depth, &last_function_name);
                    line_steps.push(event_line_step);
                }
                last_callstack_depth = line_step.location.callstack_depth;
                last_function_name = line_step.location.function_name.clone();
                line_steps.push(line_step);
            }
        }
        line_steps
    }

    fn load_call_or_return_line_step(
        &self,
        line_step: &LineStep,
        last_callstack_depth: usize,
        last_function_name: &str,
    ) -> LineStep {
        let function_name = &line_step.location.function_name;
        // TODO also location.key

        // (alexander):
        // here, the logic is different from rr/gdb backend!
        // we only iterate forward, in rr/gdb is more complex, as for reverse,
        // we iterate backwards
        // but trying initially to copy the logic was wrong, as I forgot that difference
        let (event_kind, description) = if line_step.location.callstack_depth > last_callstack_depth {
            (LineStepKind::Call, format!("call {function_name}"))
        } else {
            // <
            (LineStepKind::Return, format!("return from call {last_function_name}"))
        };
        LineStep {
            kind: event_kind,
            location: line_step.location.clone(),
            // for now preserving the same delta as step, for compat and consistensy:
            // it's used for jumping/stepping to the original line step in rr/gdb backend
            delta: line_step.delta,
            source_line: description,
            values: vec![],
        }
    }
}
