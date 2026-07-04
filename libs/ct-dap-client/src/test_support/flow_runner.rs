use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::Value;

use crate::client::{scaled, DapStdioClient};
use crate::types::flow::{FlowMode, LoadFlowArguments};
use crate::types::launch::LaunchRequestArguments;
// Note: Action and StepArg are used by the ct/step protocol (socket-based).
// For stdio-based stepping tests we use dap_step() with standard DAP command
// names instead.

use super::{find_ct_rr_support, prepare_trace_folder};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// Configuration for a flow test case.
pub struct FlowTestConfig {
    pub source_file: String,
    pub breakpoint_line: usize,
    /// Variables that SHOULD be extracted (local vars, params).
    pub expected_variables: Vec<String>,
    /// Identifiers that should NOT be extracted (function calls, macros).
    pub excluded_identifiers: Vec<String>,
    /// Expected values for specific variables (name -> expected int value).
    pub expected_values: HashMap<String, i64>,
}

/// Configuration for a multi-breakpoint flow test.
///
/// Sets breakpoints at multiple lines in the same source file, then continues
/// to each breakpoint in sequence, loading flow data and verifying expected
/// variable values at every stop.
pub struct MultiBreakpointTestConfig {
    pub source_file: String,
    /// One entry per breakpoint, in the order they will be hit.
    /// Each entry is (line, expected_variables, expected_values).
    pub breakpoints: Vec<BreakpointCheck>,
}

/// Expected state at a single breakpoint location.
pub struct BreakpointCheck {
    pub line: usize,
    /// Variable names that should appear in the flow data.
    pub expected_variables: Vec<String>,
    /// Subset of variables whose integer values must match exactly.
    pub expected_values: HashMap<String, i64>,
}

/// Configuration for a stepping test.
///
/// Hits a breakpoint, then performs a sequence of step operations (next,
/// stepIn, stepOut) and verifies the resulting line number after each step.
pub struct SteppingTestConfig {
    pub source_file: String,
    pub breakpoint_line: usize,
    /// Sequence of (step_action, expected_line_after_step).
    pub steps: Vec<(StepAction, i64)>,
}

/// The kind of step to perform in a stepping test.
#[derive(Debug, Clone, Copy)]
pub enum StepAction {
    /// Step over (DAP "next") — advance to the next line in the same scope.
    Next,
    /// Step into — descend into a function call.
    StepIn,
    /// Step out — run until the current function returns.
    StepOut,
}

/// Configuration for a call-stack test.
///
/// Hits a breakpoint and then inspects the call stack, verifying that the
/// expected function names appear in the correct order.
pub struct CallStackTestConfig {
    pub source_file: String,
    pub breakpoint_line: usize,
    /// Expected function names in the call stack, from innermost (top of
    /// stack, index 0) to outermost. The test verifies that the actual
    /// stack starts with these entries.
    pub expected_frames: Vec<String>,
    /// If set, require exactly this many total frames.
    pub expected_frame_count: Option<usize>,
}

/// Parsed flow data from a ct/updated-flow event.
#[derive(Debug)]
pub struct FlowData {
    pub steps: Vec<FlowStep>,
    /// All variable names extracted (may contain duplicates).
    pub all_variables: Vec<String>,
    /// Map of variable name to its most recent value.
    pub values: HashMap<String, Value>,
}

/// A single step in the flow.
#[derive(Debug)]
pub struct FlowStep {
    pub line: i64,
    pub variables: Vec<String>,
    pub before_values: HashMap<String, Value>,
}

fn parse_dap_int(value: &str) -> Option<i64> {
    let trimmed = value.trim().trim_matches('"');
    if let Ok(parsed) = trimmed.parse::<i64>() {
        return Some(parsed);
    }

    let mut start = None;
    for (index, ch) in trimmed.char_indices() {
        if ch == '-' || ch.is_ascii_digit() {
            start = Some(index);
            break;
        }
    }
    let start = start?;
    let end = trimmed[start..]
        .char_indices()
        .find_map(|(offset, ch)| {
            if offset > 0 && !ch.is_ascii_digit() {
                Some(start + offset)
            } else {
                None
            }
        })
        .unwrap_or(trimmed.len());
    trimmed[start..end].parse::<i64>().ok()
}

fn normalize_dap_source_name(name: &str) -> String {
    if let Some((base, suffix)) = name.rsplit_once("_p") {
        if !base.is_empty() && suffix.chars().all(|ch| ch.is_ascii_digit()) {
            return base.to_string();
        }
    }

    let Some((base, suffix)) = name.rsplit_once('_') else {
        return name.to_string();
    };
    if !base.is_empty() && suffix.chars().all(|ch| ch.is_ascii_digit()) {
        base.to_string()
    } else {
        name.to_string()
    }
}

impl FlowData {
    /// Parse the ct/updated-flow event body into FlowData.
    pub fn from_event_body(body: &Value) -> Result<Self, BoxError> {
        let view_updates = body
            .get("viewUpdates")
            .and_then(|v| v.as_array())
            .ok_or("viewUpdates should exist")?;

        let first_update = view_updates
            .first()
            .ok_or("should have at least one view update")?;

        let steps_json = first_update
            .get("steps")
            .and_then(|s| s.as_array())
            .ok_or("steps should exist")?;

        let mut steps = Vec::new();
        let mut all_variables = Vec::new();
        let mut values = HashMap::new();

        for step_json in steps_json {
            let line = step_json
                .get("position")
                .and_then(|l| l.as_i64())
                .or_else(|| step_json.get("line").and_then(|l| l.as_i64()))
                .unwrap_or(0);

            let mut variables = Vec::new();
            if let Some(expr_order) = step_json.get("exprOrder").and_then(|e| e.as_array()) {
                for expr in expr_order {
                    if let Some(var_name) = expr.as_str() {
                        variables.push(var_name.to_string());
                        all_variables.push(var_name.to_string());
                    }
                }
            }

            let mut before_values = HashMap::new();
            if let Some(bv) = step_json.get("beforeValues").and_then(|v| v.as_object()) {
                for (var_name, value) in bv {
                    before_values.insert(var_name.clone(), value.clone());
                    values.insert(var_name.clone(), value.clone());
                }
            }

            steps.push(FlowStep {
                line,
                variables,
                before_values,
            });
        }

        Ok(FlowData {
            steps,
            all_variables,
            values,
        })
    }

    /// Check if a value was successfully loaded (not `<NONE>`).
    pub fn is_value_loaded(value: &Value) -> bool {
        if let Some(r_val) = value.get("r").and_then(|v| v.as_str()) {
            return r_val != "<NONE>";
        }
        false
    }

    /// Extract an integer value from a flow value structure.
    pub fn extract_int_value(value: &Value) -> Option<i64> {
        if let Some(i_val) = value.get("i").and_then(|v| v.as_str()) {
            if !i_val.is_empty() {
                if let Ok(n) = i_val.parse::<i64>() {
                    return Some(n);
                }
            }
        }
        if let Some(r_val) = value.get("r").and_then(|v| v.as_str()) {
            if r_val != "<NONE>" && !r_val.is_empty() {
                if let Ok(n) = r_val.parse::<i64>() {
                    return Some(n);
                }
            }
        }
        None
    }
}

/// High-level test runner that manages the DAP lifecycle for flow tests.
pub struct FlowTestRunner {
    client: DapStdioClient,
    _trace_wrapper: Option<PathBuf>,
}

impl FlowTestRunner {
    /// Spawn db-backend, run DAP init sequence with the given RR trace folder.
    pub fn new(db_backend_bin: &Path, rr_trace_dir: &Path) -> Result<Self, BoxError> {
        Self::new_with_target_pid(db_backend_bin, rr_trace_dir, None)
    }

    /// Spawn db-backend with additional environment variables, then run the DAP
    /// init sequence with the given RR/MCR trace folder.
    pub fn new_with_envs(
        db_backend_bin: &Path,
        rr_trace_dir: &Path,
        extra_envs: &[(&str, &str)],
    ) -> Result<Self, BoxError> {
        Self::new_with_target_pid_and_envs(db_backend_bin, rr_trace_dir, None, extra_envs)
    }

    /// Spawn db-backend targeting a specific process in a multi-process trace.
    ///
    /// When `target_pid` is `Some(pid)`, the replay worker (`ct-native-replay`)
    /// is instructed via the `CT_NATIVE_REPLAY_TARGET_PID` environment variable
    /// to start `rr replay -f <pid>` (for fork-only children) or `-p <pid>`
    /// (for exec'd children) instead of following the root process. This
    /// allows DAP-based flow tests to inspect child-process code paths in
    /// recordings produced by `m2_parent.c`, `m3_pipe_parent.c`, etc., where
    /// the breakpoint line is reached only by the child process.
    pub fn new_with_target_pid(
        db_backend_bin: &Path,
        rr_trace_dir: &Path,
        target_pid: Option<u32>,
    ) -> Result<Self, BoxError> {
        Self::new_with_target_pid_and_envs(db_backend_bin, rr_trace_dir, target_pid, &[])
    }

    fn new_with_target_pid_and_envs(
        db_backend_bin: &Path,
        rr_trace_dir: &Path,
        target_pid: Option<u32>,
        extra_envs: &[(&str, &str)],
    ) -> Result<Self, BoxError> {
        let t0 = std::time::Instant::now();
        let (launch_folder, wrapper) = prepare_trace_folder(rr_trace_dir)?;
        let ct_rr_worker_exe = extra_envs
            .iter()
            .find_map(|(name, value)| match *name {
                "CT_NATIVE_REPLAY_BIN" | "CODETRACER_CT_NATIVE_REPLAY_CMD" => {
                    Some(PathBuf::from(value))
                }
                _ => None,
            })
            .filter(|path| path.is_file())
            .map(Ok)
            .unwrap_or_else(find_ct_rr_support)?;

        let pid_str = target_pid.map(|p| p.to_string());
        let mut envs = extra_envs.to_vec();
        if let Some(s) = pid_str.as_deref() {
            envs.push(("CT_NATIVE_REPLAY_TARGET_PID", s));
        }
        let mut client = DapStdioClient::spawn_with_envs(db_backend_bin, &envs)?;
        eprintln!("[flow-runner] spawn: {:.1}s", t0.elapsed().as_secs_f64());

        let _caps = client.initialize()?;
        eprintln!(
            "[flow-runner] initialize: {:.1}s",
            t0.elapsed().as_secs_f64()
        );

        client.launch(LaunchRequestArguments {
            trace_folder: Some(launch_folder),
            ct_rr_worker_exe: Some(ct_rr_worker_exe),
            ..Default::default()
        })?;
        eprintln!("[flow-runner] launch: {:.1}s", t0.elapsed().as_secs_f64());

        client.configuration_done()?;
        eprintln!(
            "[flow-runner] configurationDone: {:.1}s",
            t0.elapsed().as_secs_f64()
        );

        // Use the scaled timeout: under parallel `just test` load the
        // db-backend/RR/LLDB pipeline can take noticeably longer than the
        // best-case ~0.5s to reach the initial `stopped` event. See
        // `client::scaled` for the rationale and override knob.
        client.wait_for_stopped(scaled(Duration::from_secs(10)))?;
        eprintln!("[flow-runner] stopped: {:.1}s", t0.elapsed().as_secs_f64());

        Ok(FlowTestRunner {
            client,
            _trace_wrapper: wrapper,
        })
    }

    /// Spawn db-backend, run DAP init sequence with a DB trace folder.
    ///
    /// Unlike `new()` (for RR traces), this does NOT need ct-rr-support or
    /// prepare_trace_folder. DB traces (Python, Ruby, JavaScript, Noir, WASM)
    /// are self-contained: the trace folder contains a single `<program>.ct`
    /// CTFS container that db-backend opens directly. Legacy
    /// `trace.json`/`trace.bin` + `trace_metadata.json` triplets are no
    /// longer accepted.
    pub fn new_db_trace(db_backend_bin: &Path, trace_dir: &Path) -> Result<Self, BoxError> {
        Self::new_db_trace_with_timeout(db_backend_bin, trace_dir, scaled(Duration::from_secs(10)))
    }

    /// Spawn db-backend for a DB trace and wait up to `startup_timeout` for
    /// the initial stopped event.  Used by recorders whose first launch is
    /// noticeably slower (e.g. BEAM bundles need to materialize manifests
    /// and compile fixtures inside the recorder dev shell).
    pub fn new_db_trace_with_timeout(
        db_backend_bin: &Path,
        trace_dir: &Path,
        startup_timeout: Duration,
    ) -> Result<Self, BoxError> {
        let mut client = DapStdioClient::spawn(db_backend_bin)?;

        let _caps = client.initialize()?;

        client.launch(LaunchRequestArguments {
            trace_folder: Some(trace_dir.to_path_buf()),
            ..Default::default()
        })?;

        client.configuration_done()?;
        client.wait_for_stopped(startup_timeout)?;

        Ok(FlowTestRunner {
            client,
            _trace_wrapper: None,
        })
    }

    /// Run the flow test: set breakpoint, continue to it, load flow, verify results.
    pub fn run_and_verify(&mut self, config: &FlowTestConfig) -> Result<(), BoxError> {
        // 1. Set breakpoint
        self.client
            .set_breakpoints(&config.source_file, &[config.breakpoint_line])?;

        // 2. Continue to breakpoint
        let move_state = self.client.dap_continue()?;
        println!(
            "Stopped at {}:{}",
            move_state.location.path, move_state.location.line
        );

        // 3. Load flow at current location
        let flow_body = self.client.load_flow(LoadFlowArguments {
            flow_mode: FlowMode::Call,
            location: move_state.location,
        })?;

        // 4. Parse flow data
        let flow = FlowData::from_event_body(&flow_body)?;

        // 5. Verify
        self.verify_flow_results(config, &flow)?;

        Ok(())
    }

    /// Run to the configured breakpoint and verify locals via CodeTracer's DAP variables extension.
    pub fn run_and_verify_dap_variables(
        &mut self,
        config: &FlowTestConfig,
    ) -> Result<(), BoxError> {
        self.client
            .set_breakpoints(&config.source_file, &[config.breakpoint_line])?;

        let move_state = self.client.dap_continue()?;
        println!(
            "Stopped at {}:{}",
            move_state.location.path, move_state.location.line
        );

        let locals = self.client.load_locals()?;
        let local_list = locals
            .get("locals")
            .and_then(Value::as_array)
            .ok_or("ct/load-locals response did not contain a locals array")?;

        let mut values = HashMap::new();
        for local in local_list {
            let Some(name) = local.get("expression").and_then(Value::as_str) else {
                continue;
            };
            let value = local.get("value").cloned().unwrap_or(Value::Null);
            values.insert(name.to_string(), value.clone());
            values
                .entry(normalize_dap_source_name(name))
                .or_insert(value);
        }

        for expected in &config.expected_variables {
            if !values.contains_key(expected) {
                return Err(format!(
                    "DAP variables did not include expected variable {expected:?}; got {:?}",
                    values.keys().collect::<Vec<_>>()
                )
                .into());
            }
        }

        for (name, expected) in &config.expected_values {
            let actual = values
                .get(name)
                .ok_or_else(|| format!("DAP variables did not include expected value {name:?}"))?;
            let actual_int = FlowData::extract_int_value(actual)
                .or_else(|| parse_dap_int(&actual.to_string()))
                .ok_or_else(|| {
                    format!("DAP variable {name:?} value {actual:?} was not an integer")
                })?;
            if actual_int != *expected {
                return Err(format!(
                    "DAP variable {name:?} value mismatch: expected {expected}, got {actual_int} ({actual:?})"
                )
                .into());
            }
        }

        Ok(())
    }

    fn verify_flow_results(
        &self,
        config: &FlowTestConfig,
        flow: &FlowData,
    ) -> Result<(), BoxError> {
        verify_flow_results(config, flow)
    }

    /// Run a multi-breakpoint test: set breakpoints at several lines, then
    /// continue to each one in order, loading flow data and verifying variables
    /// at every stop.
    pub fn run_multi_breakpoint(
        &mut self,
        config: &MultiBreakpointTestConfig,
    ) -> Result<(), BoxError> {
        // Collect all breakpoint lines and set them in one request.
        let lines: Vec<usize> = config.breakpoints.iter().map(|b| b.line).collect();
        self.client.set_breakpoints(&config.source_file, &lines)?;

        for (i, bp) in config.breakpoints.iter().enumerate() {
            println!(
                "\n--- Multi-breakpoint: continuing to breakpoint {} (line {}) ---",
                i + 1,
                bp.line
            );

            let move_state = self.client.dap_continue()?;
            println!(
                "  Stopped at {}:{} key={} ticks={} fn={}..{}",
                move_state.location.path,
                move_state.location.line,
                move_state.location.key,
                move_state.location.rr_ticks.0,
                move_state.location.function_first,
                move_state.location.function_last
            );

            // Load flow and verify variables at this breakpoint.
            let flow_body = self.client.load_flow(LoadFlowArguments {
                flow_mode: FlowMode::Call,
                location: move_state.location,
            })?;
            let flow = FlowData::from_event_body(&flow_body)?;

            // Build a FlowTestConfig for the verification helper.
            let check_config = FlowTestConfig {
                source_file: config.source_file.clone(),
                breakpoint_line: bp.line,
                expected_variables: bp.expected_variables.clone(),
                excluded_identifiers: vec![],
                expected_values: bp.expected_values.clone(),
            };
            verify_flow_results(&check_config, &flow)
                .map_err(|e| format!("Breakpoint {} (line {}): {}", i + 1, bp.line, e))?;
        }

        println!("\nMulti-breakpoint test completed successfully!");
        Ok(())
    }

    /// Run a stepping test: hit a breakpoint, then perform a sequence of step
    /// operations (next / stepIn / stepOut) and verify the debugger lands on
    /// the expected line after each step.
    ///
    /// Uses the standard DAP step commands (`next`, `stepIn`, `stepOut`)
    /// via `dap_step`, which is compatible with the stdio-based DAP server.
    pub fn run_stepping_test(&mut self, config: &SteppingTestConfig) -> Result<(), BoxError> {
        // Set breakpoint and continue to it.
        self.client
            .set_breakpoints(&config.source_file, &[config.breakpoint_line])?;
        let move_state = self.client.dap_continue()?;
        println!(
            "Stepping test: hit breakpoint at {}:{}",
            move_state.location.path, move_state.location.line
        );

        // Clear the breakpoint so subsequent continues don't re-hit it.
        self.client.set_breakpoints(&config.source_file, &[])?;

        for (i, (action, expected_line)) in config.steps.iter().enumerate() {
            let dap_command = match action {
                StepAction::Next => "next",
                StepAction::StepIn => "stepIn",
                StepAction::StepOut => "stepOut",
            };

            let result = self.client.dap_step(dap_command)?;

            let actual_line = result.location.line;
            println!(
                "  Step {} ({:?}): expected line {}, got line {}",
                i + 1,
                action,
                expected_line,
                actual_line
            );

            if actual_line != *expected_line {
                return Err(format!(
                    "Step {} ({:?}): expected line {}, but debugger stopped at line {}",
                    i + 1,
                    action,
                    expected_line,
                    actual_line
                )
                .into());
            }
        }

        println!("\nStepping test completed successfully!");
        Ok(())
    }

    /// Run a call-stack test: hit a breakpoint, then request the stack trace
    /// and verify that the expected function names appear in the correct order.
    pub fn run_call_stack_test(&mut self, config: &CallStackTestConfig) -> Result<(), BoxError> {
        // Set breakpoint and continue to it.
        self.client
            .set_breakpoints(&config.source_file, &[config.breakpoint_line])?;
        let move_state = self.client.dap_continue()?;
        println!(
            "Call-stack test: hit breakpoint at {}:{}",
            move_state.location.path, move_state.location.line
        );

        // Request the call stack.
        let stack = self.client.stack_trace()?;
        let frame_names: Vec<&str> = stack.stack_frames.iter().map(|f| f.name.as_str()).collect();
        println!("  Stack frames ({}): {:?}", frame_names.len(), frame_names);

        // Verify expected frame count if specified.
        if let Some(expected_count) = config.expected_frame_count {
            if stack.stack_frames.len() != expected_count {
                return Err(format!(
                    "Expected {} stack frames, got {} (frames: {:?})",
                    expected_count,
                    stack.stack_frames.len(),
                    frame_names
                )
                .into());
            }
        }

        // Verify that the actual stack starts with the expected frame names.
        if stack.stack_frames.len() < config.expected_frames.len() {
            return Err(format!(
                "Expected at least {} stack frames, got {} (frames: {:?})",
                config.expected_frames.len(),
                stack.stack_frames.len(),
                frame_names
            )
            .into());
        }

        for (i, expected_name) in config.expected_frames.iter().enumerate() {
            let actual_name = &stack.stack_frames[i].name;
            if actual_name != expected_name {
                return Err(format!(
                    "Stack frame {}: expected '{}', got '{}' (full stack: {:?})",
                    i, expected_name, actual_name, frame_names
                )
                .into());
            }
        }

        println!("\nCall-stack test completed successfully!");
        Ok(())
    }

    /// Access the underlying client for additional operations.
    pub fn client(&mut self) -> &mut DapStdioClient {
        &mut self.client
    }

    /// Clean shutdown.
    pub fn finish(self) -> Result<(), BoxError> {
        self.client.disconnect()?;
        Ok(())
    }
}

/// Verify flow results against the expected configuration.
///
/// This is extracted as a free function so it can be unit-tested without
/// needing a full `FlowTestRunner` (which requires a live DAP subprocess).
/// The `FlowTestRunner::verify_flow_results` method delegates to this.
fn verify_flow_results(config: &FlowTestConfig, flow: &FlowData) -> Result<(), BoxError> {
    println!("\nVerifying flow data...");
    println!(
        "  Total steps: {}, all_variables: {:?}",
        flow.steps.len(),
        flow.all_variables
    );

    // Check excluded identifiers are NOT in the list
    for excluded in &config.excluded_identifiers {
        if flow.all_variables.contains(excluded) {
            return Err(format!(
                "'{}' should not be extracted as a variable (it's a function call)",
                excluded
            )
            .into());
        }
    }
    println!("  Function call filtering PASSED");

    // Check expected variables ARE in the list
    let found_expected: Vec<&String> = config
        .expected_variables
        .iter()
        .filter(|v| flow.all_variables.contains(v))
        .collect();
    println!("  Expected variables found: {:?}", found_expected);

    if found_expected.is_empty() {
        return Err(format!(
            "should find at least some of the expected variables: {:?}",
            config.expected_variables
        )
        .into());
    }
    println!("  Variable extraction PASSED");

    // Check value loading
    let mut loaded = 0;
    let mut not_loaded = 0;
    for value in flow.values.values() {
        if FlowData::is_value_loaded(value) {
            loaded += 1;
        } else {
            not_loaded += 1;
        }
    }
    println!("  Loaded: {}, Not loaded: {}", loaded, not_loaded);

    // Verify specific expected values — every entry in expected_values
    // MUST be present, loaded, parseable, and correct.
    let mut verified_count = 0;
    for (var_name, expected_value) in &config.expected_values {
        if let Some(value) = flow.values.get(var_name) {
            if FlowData::is_value_loaded(value) {
                if let Some(actual) = FlowData::extract_int_value(value) {
                    if actual != *expected_value {
                        return Err(format!(
                            "{} should be {}, got {}",
                            var_name, expected_value, actual
                        )
                        .into());
                    }
                    println!("  {} = {} (correct)", var_name, actual);
                    verified_count += 1;
                } else {
                    return Err(format!(
                        "variable '{}' has a loaded value but it could not be \
                         extracted as an integer (raw value: {:?})",
                        var_name, value
                    )
                    .into());
                }
            } else {
                println!("  {} = <NONE>", var_name);
                return Err(format!(
                    "variable '{}' is present but its value was not loaded (<NONE>)",
                    var_name
                )
                .into());
            }
        } else {
            return Err(format!(
                "expected variable '{}' is missing from flow.values (available: {:?})",
                var_name,
                flow.values.keys().collect::<Vec<_>>()
            )
            .into());
        }
    }

    if !config.expected_values.is_empty() && verified_count != config.expected_values.len() {
        return Err(format!(
            "only {}/{} expected values were verified",
            verified_count,
            config.expected_values.len()
        )
        .into());
    }

    if loaded == 0 {
        return Err("No values were loaded - local variables should be loadable".into());
    }
    println!("  Value loading PASSED for {} variables", loaded);
    println!("\nFlow test completed successfully!");

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Build a minimal `FlowTestConfig` expecting a single variable with a
    /// specific integer value.
    fn config_expecting(var_name: &str, value: i64) -> FlowTestConfig {
        let mut expected_values = HashMap::new();
        expected_values.insert(var_name.to_string(), value);
        FlowTestConfig {
            source_file: "test.c".to_string(),
            breakpoint_line: 1,
            expected_variables: vec![var_name.to_string()],
            excluded_identifiers: vec![],
            expected_values,
        }
    }

    /// Build a `FlowData` containing one step with the given variable names
    /// and their associated flow values.
    ///
    /// Each entry in `vars` is `(name, value_json)` where `value_json` is the
    /// flow-format value object (e.g. `{"r": "42", "i": "42"}`).
    fn flow_with_vars(vars: &[(&str, Value)]) -> FlowData {
        let mut all_variables = Vec::new();
        let mut values = HashMap::new();
        let mut step_variables = Vec::new();
        let mut before_values = HashMap::new();

        for (name, val) in vars {
            let name = name.to_string();
            all_variables.push(name.clone());
            step_variables.push(name.clone());
            before_values.insert(name.clone(), val.clone());
            values.insert(name, val.clone());
        }

        FlowData {
            steps: vec![FlowStep {
                line: 1,
                variables: step_variables,
                before_values,
            }],
            all_variables,
            values,
        }
    }

    /// Helper to build the flow-format value JSON for an integer.
    /// The format stores both a representation string (`r`) and an integer
    /// string (`i`), matching what `FlowData::extract_int_value` expects.
    fn int_flow_value(n: i64) -> Value {
        json!({"r": n.to_string(), "i": n.to_string()})
    }

    #[test]
    fn test_verify_rejects_missing_variable() {
        let config = config_expecting("x", 42);
        // FlowData has variable "y" but NOT "x".
        let flow = flow_with_vars(&[("y", int_flow_value(10))]);

        let result = verify_flow_results(&config, &flow);
        assert!(
            result.is_err(),
            "verify_flow_results should return Err when expected variable is absent"
        );
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("x"),
            "error message should mention the missing variable 'x', got: {}",
            err_msg
        );
    }

    #[test]
    fn test_verify_rejects_wrong_value() {
        let config = config_expecting("x", 42);
        // FlowData has "x" but with value 99 instead of 42.
        let flow = flow_with_vars(&[("x", int_flow_value(99))]);

        let result = verify_flow_results(&config, &flow);
        assert!(
            result.is_err(),
            "verify_flow_results should return Err when variable has wrong value"
        );
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("42") && err_msg.contains("99"),
            "error message should mention both expected (42) and actual (99), got: {}",
            err_msg
        );
    }

    #[test]
    fn test_verify_accepts_correct_values() {
        let config = config_expecting("x", 42);
        let flow = flow_with_vars(&[("x", int_flow_value(42))]);

        let result = verify_flow_results(&config, &flow);
        assert!(
            result.is_ok(),
            "verify_flow_results should return Ok when values match, got: {:?}",
            result.unwrap_err()
        );
    }

    #[test]
    fn test_verify_rejects_excluded_identifier() {
        let config = FlowTestConfig {
            source_file: "test.c".to_string(),
            breakpoint_line: 1,
            expected_variables: vec!["x".to_string()],
            excluded_identifiers: vec!["printf".to_string()],
            expected_values: HashMap::new(),
        };
        // FlowData contains both "x" and "printf" — printf should be rejected.
        let flow = flow_with_vars(&[("x", int_flow_value(10)), ("printf", int_flow_value(0))]);

        let result = verify_flow_results(&config, &flow);
        assert!(
            result.is_err(),
            "verify_flow_results should reject flow containing excluded identifier"
        );
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("printf"),
            "error should mention the excluded identifier, got: {}",
            err_msg
        );
    }

    #[test]
    fn test_verify_rejects_unloaded_value() {
        let config = config_expecting("x", 42);
        // Value is present but marked as unloaded (<NONE>).
        let flow = flow_with_vars(&[("x", json!({"r": "<NONE>", "i": ""}))]);

        let result = verify_flow_results(&config, &flow);
        assert!(
            result.is_err(),
            "verify_flow_results should reject unloaded values"
        );
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("not loaded") || err_msg.contains("NONE"),
            "error should mention value not being loaded, got: {}",
            err_msg
        );
    }

    #[test]
    fn test_verify_rejects_non_integer_value() {
        let config = config_expecting("x", 42);
        // Value is loaded but not parseable as integer.
        let flow = flow_with_vars(&[("x", json!({"r": "hello", "i": ""}))]);

        let result = verify_flow_results(&config, &flow);
        assert!(
            result.is_err(),
            "verify_flow_results should reject non-integer values when integer expected"
        );
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("integer") || err_msg.contains("extracted"),
            "error should mention integer extraction failure, got: {}",
            err_msg
        );
    }

    #[test]
    fn test_verify_accepts_multiple_variables() {
        let mut expected_values = HashMap::new();
        expected_values.insert("a".to_string(), 10);
        expected_values.insert("b".to_string(), 20);
        expected_values.insert("sum".to_string(), 30);
        let config = FlowTestConfig {
            source_file: "test.c".to_string(),
            breakpoint_line: 1,
            expected_variables: vec!["a".to_string(), "b".to_string(), "sum".to_string()],
            excluded_identifiers: vec![],
            expected_values,
        };
        let flow = flow_with_vars(&[
            ("a", int_flow_value(10)),
            ("b", int_flow_value(20)),
            ("sum", int_flow_value(30)),
        ]);

        let result = verify_flow_results(&config, &flow);
        assert!(
            result.is_ok(),
            "verify_flow_results should accept all correct multi-variable values, got: {:?}",
            result.unwrap_err()
        );
    }

    #[test]
    fn test_verify_rejects_when_no_values_loaded() {
        // Config with no expected_values but flow has only unloaded values.
        let config = FlowTestConfig {
            source_file: "test.c".to_string(),
            breakpoint_line: 1,
            expected_variables: vec!["x".to_string()],
            excluded_identifiers: vec![],
            expected_values: HashMap::new(),
        };
        let flow = flow_with_vars(&[("x", json!({"r": "<NONE>", "i": ""}))]);

        let result = verify_flow_results(&config, &flow);
        assert!(
            result.is_err(),
            "verify_flow_results should reject when zero values are loaded"
        );
    }
}
