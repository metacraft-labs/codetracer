//! Python bridge: translates simplified Python navigation requests into
//! multi-step DAP interactions with the backend.
//!
//! The Python client sends `ct/py-navigate` requests with a `method` field
//! (e.g., `"step_over"`) and the daemon translates them into the following
//! DAP interaction sequence:
//!
//! 1. Send the corresponding DAP navigation command (e.g., `next`) to the backend.
//! 2. Wait for the backend to emit a `stopped` (or `terminated`) event.
//! 3. Send a `stackTrace` request to the backend.
//! 4. Wait for the `stackTrace` response.
//! 5. Extract the location (path, line, column, ticks) from the top stack frame.
//! 6. Return a simplified response to the Python client.
//!
//! This module contains the data structures and helpers; the actual integration
//! with the daemon's dispatch and routing logic lives in `backend_manager.rs`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde_json::Value;

// ---------------------------------------------------------------------------
// BreakpointState — per-trace breakpoint and watchpoint tracking
// ---------------------------------------------------------------------------

/// Per-trace breakpoint and watchpoint state tracked by the daemon.
///
/// Needed because the DAP `setBreakpoints` command is per-file: each call
/// sends ALL breakpoints for a given source file.  The daemon must maintain
/// a mapping of breakpoint IDs to (file, line) pairs so that it can
/// reconstruct the full breakpoint list for each file when adding or
/// removing individual breakpoints.
///
/// Similarly, `setDataBreakpoints` replaces all data breakpoints each time,
/// so the daemon tracks watchpoints in the same structure.
#[derive(Debug, Default)]
pub struct BreakpointState {
    /// Next breakpoint ID to assign (monotonically increasing, starting at 1).
    next_bp_id: i64,
    /// Next watchpoint ID to assign (monotonically increasing, starting at 1).
    next_wp_id: i64,
    /// Active breakpoints: maps breakpoint_id -> (source_path, line).
    breakpoints: HashMap<i64, (String, i64)>,
    /// Active watchpoints: maps watchpoint_id -> expression.
    watchpoints: HashMap<i64, String>,
}

impl BreakpointState {
    /// Adds a breakpoint at the given source location.
    ///
    /// Returns `(bp_id, all_breakpoint_lines_for_the_affected_file)`.
    /// The caller must send a `setBreakpoints` DAP command to the backend
    /// with the full list of lines for the affected file.
    pub fn add_breakpoint(&mut self, source_path: &str, line: i64) -> (i64, Vec<i64>) {
        self.next_bp_id += 1;
        let bp_id = self.next_bp_id;
        self.breakpoints
            .insert(bp_id, (source_path.to_string(), line));
        let lines = self.breakpoints_for_file(source_path);
        (bp_id, lines)
    }

    /// Removes a breakpoint by its ID.
    ///
    /// Returns `Some((source_path, remaining_lines_for_file))` if the
    /// breakpoint existed, or `None` if the ID was unknown.
    pub fn remove_breakpoint(&mut self, bp_id: i64) -> Option<(String, Vec<i64>)> {
        if let Some((source_path, _line)) = self.breakpoints.remove(&bp_id) {
            let remaining = self.breakpoints_for_file(&source_path);
            Some((source_path, remaining))
        } else {
            None
        }
    }

    /// Returns all breakpoint lines for a given source file.
    pub fn breakpoints_for_file(&self, source_path: &str) -> Vec<i64> {
        self.breakpoints
            .values()
            .filter(|(f, _)| f == source_path)
            .map(|(_, l)| *l)
            .collect()
    }

    /// Adds a watchpoint on the given expression.
    ///
    /// Returns `(wp_id, all_active_expressions)`.
    pub fn add_watchpoint(&mut self, expression: &str) -> (i64, Vec<String>) {
        self.next_wp_id += 1;
        let wp_id = self.next_wp_id;
        self.watchpoints.insert(wp_id, expression.to_string());
        let all = self.all_watchpoint_expressions();
        (wp_id, all)
    }

    /// Removes a watchpoint by its ID.
    ///
    /// Returns `Some(remaining_expressions)` if the watchpoint existed,
    /// or `None` if the ID was unknown.
    pub fn remove_watchpoint(&mut self, wp_id: i64) -> Option<Vec<String>> {
        if self.watchpoints.remove(&wp_id).is_some() {
            Some(self.all_watchpoint_expressions())
        } else {
            None
        }
    }

    /// Returns all active watchpoint expressions.
    pub fn all_watchpoint_expressions(&self) -> Vec<String> {
        self.watchpoints.values().cloned().collect()
    }
}

// ---------------------------------------------------------------------------
// PyBridgeState
// ---------------------------------------------------------------------------

/// State for tracking active Python bridge navigation operations and
/// synchronous request-response operations (locals, evaluate, stack trace).
///
/// The daemon holds one `PyBridgeState` instance in its `DaemonState`.
/// Each `ct/py-navigate` request creates a [`PendingPyNavigation`] that
/// progresses through a state machine as DAP messages flow back from
/// the backend.
///
/// Simpler request-response operations (`ct/py-locals`, `ct/py-evaluate`,
/// `ct/py-stack-trace`) create a [`PendingPyRequest`] that is resolved
/// when the backend returns a response with the matching `request_seq`.
#[derive(Debug, Default)]
pub struct PyBridgeState {
    /// Pending navigation operations waiting for completion.
    pub pending_navigations: Vec<PendingPyNavigation>,
    /// Pending simple request-response operations (locals, evaluate,
    /// stack trace) waiting for the backend's response.
    pub pending_requests: Vec<PendingPyRequest>,
    /// Counter for generating unique DAP seq numbers for bridge-initiated
    /// requests (e.g., `stackTrace`).  Starts at 1,000,000 to avoid
    /// conflicts with client-originated seq numbers.
    pub next_seq: i64,
    /// Per-trace breakpoint and watchpoint state.
    ///
    /// Keyed by the canonical trace path (same key used by the session
    /// manager).  Created lazily on first breakpoint/watchpoint operation.
    pub breakpoint_states: HashMap<PathBuf, BreakpointState>,
}

impl PyBridgeState {
    pub fn new() -> Self {
        Self {
            pending_navigations: Vec::new(),
            pending_requests: Vec::new(),
            next_seq: 1_000_000,
            breakpoint_states: HashMap::new(),
        }
    }

    /// Returns the next unique seq number for bridge-initiated DAP requests.
    pub fn next_seq(&mut self) -> i64 {
        let seq = self.next_seq;
        self.next_seq += 1;
        seq
    }

    /// Returns the breakpoint state for the given trace path, creating it
    /// if it does not already exist.
    pub fn breakpoint_state_mut(&mut self, trace_path: &Path) -> &mut BreakpointState {
        self.breakpoint_states
            .entry(trace_path.to_path_buf())
            .or_default()
    }
}

// ---------------------------------------------------------------------------
// PendingPyNavigation
// ---------------------------------------------------------------------------

/// A pending Python navigation request waiting for DAP completion.
///
/// Tracks the multi-step DAP interaction from the initial navigation
/// command through to the `stackTrace` response that provides the
/// final location.
#[derive(Debug)]
pub struct PendingPyNavigation {
    /// The backend ID handling this trace.
    pub backend_id: usize,
    /// The client that sent the Python request.
    pub client_id: u64,
    /// The seq number of the original Python client request.
    pub original_seq: i64,
    /// Current state of the multi-step DAP interaction.
    pub state: PendingPyNavState,
    /// The seq number of the `stackTrace` request sent to the backend
    /// (populated when transitioning to `AwaitingStackTrace`).
    pub stack_trace_seq: Option<i64>,
    /// The seq number of the DAP navigation command (e.g., `next`, `stepIn`)
    /// sent to the backend.  Used to silently consume the backend's response
    /// to this command so it is not broadcast to clients.
    pub nav_command_seq: Option<i64>,
}

// ---------------------------------------------------------------------------
// PendingPyNavState
// ---------------------------------------------------------------------------

/// State machine for a pending Python navigation.
///
/// Transitions: `AwaitingStopped` -> `AwaitingStackTrace` -> (completed).
#[derive(Debug, PartialEq)]
pub enum PendingPyNavState {
    /// Waiting for a `stopped` event from the backend after sending
    /// the navigation DAP command.
    AwaitingStopped,
    /// Waiting for the `stackTrace` response after the stopped event.
    AwaitingStackTrace,
}

// ---------------------------------------------------------------------------
// PendingPyRequest (simple request-response operations)
// ---------------------------------------------------------------------------

/// The kind of a pending Python bridge request.
///
/// Unlike navigation (`ct/py-navigate`), these are synchronous
/// single-request / single-response operations — there is no state
/// machine, just a matching `request_seq` to wait for.
#[derive(Debug, PartialEq)]
pub enum PendingPyRequestKind {
    /// `ct/py-locals` -> backend `ct/load-locals`.
    Locals,
    /// `ct/py-evaluate` -> backend `evaluate`.
    Evaluate,
    /// `ct/py-stack-trace` -> backend `stackTrace`.
    StackTrace,
    /// `ct/py-flow` -> backend `ct/load-flow`.
    Flow,
    /// Fire-and-forget commands (e.g., `setBreakpoints`, `setDataBreakpoints`)
    /// whose backend responses should be silently consumed and not forwarded
    /// to any client.
    FireAndForget,
}

/// A pending synchronous Python bridge request waiting for a backend
/// response.
///
/// When the daemon receives `ct/py-locals`, `ct/py-evaluate`, or
/// `ct/py-stack-trace` from a Python client, it translates the request
/// into the corresponding DAP command and forwards it to the backend.
/// A `PendingPyRequest` is registered so that when the backend response
/// arrives, the daemon can format it and send it back to the Python
/// client.
#[derive(Debug)]
pub struct PendingPyRequest {
    /// The kind of operation.
    pub kind: PendingPyRequestKind,
    /// The client that sent the Python request.
    pub client_id: u64,
    /// The seq number of the original Python client request.
    pub original_seq: i64,
    /// The seq number of the DAP request sent to the backend.
    pub backend_seq: i64,
    /// The command name to use in the response (e.g., `"ct/py-locals"`).
    pub response_command: String,
}

/// Formats a backend `ct/load-locals` response into the simplified
/// `ct/py-locals` response body.
///
/// The backend returns variables in its own format; this function
/// extracts the `variables` array from the response body and passes
/// it through directly (the mock and real backend both use the same
/// `{name, value, type, children}` schema).
///
/// Returns `(success, body_or_error)`:
/// - On success: `(true, json!({"variables": [...]}))`
/// - On failure: `(false, json!({"message": "..."}))`
pub fn format_locals_response(backend_response: &Value) -> (bool, Value) {
    let success = backend_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if !success {
        let message = backend_response
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("load-locals failed");
        return (false, serde_json::json!({"message": message}));
    }

    let variables = backend_response
        .get("body")
        .and_then(|b| b.get("variables"))
        .cloned()
        .unwrap_or_else(|| serde_json::json!([]));

    (true, serde_json::json!({"variables": variables}))
}

/// Formats a backend `evaluate` response into the simplified
/// `ct/py-evaluate` response.
///
/// Returns `(success, body_or_error)`:
/// - On success: `(true, json!({"result": "...", "type": "..."}))`
/// - On failure: `(false, json!({"message": "..."}))`
pub fn format_evaluate_response(backend_response: &Value) -> (bool, Value) {
    let success = backend_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if !success {
        let message = backend_response
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("evaluation failed");
        return (false, serde_json::json!({"message": message}));
    }

    let body = backend_response
        .get("body")
        .unwrap_or(&Value::Null);

    let result = body
        .get("result")
        .and_then(Value::as_str)
        .unwrap_or("");
    let type_name = body
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("");

    (true, serde_json::json!({"result": result, "type": type_name}))
}

/// Formats a backend `stackTrace` response into the simplified
/// `ct/py-stack-trace` response body.
///
/// Extracts the `stackFrames` array and converts each frame into
/// `{id, name, location: {path, line, column}}`.
///
/// Returns `(success, body)`.
pub fn format_stack_trace_response(backend_response: &Value) -> (bool, Value) {
    let success = backend_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if !success {
        let message = backend_response
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("stackTrace failed");
        return (false, serde_json::json!({"message": message}));
    }

    let body = backend_response
        .get("body")
        .unwrap_or(&Value::Null);
    let frames_raw = body
        .get("stackFrames")
        .and_then(Value::as_array);

    let frames: Vec<Value> = match frames_raw {
        Some(arr) => arr
            .iter()
            .map(|frame| {
                let id = frame.get("id").and_then(Value::as_i64).unwrap_or(0);
                let name = frame
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let path = frame
                    .get("source")
                    .and_then(|s| s.get("path"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let line = frame.get("line").and_then(Value::as_i64).unwrap_or(0);
                let column = frame.get("column").and_then(Value::as_i64).unwrap_or(0);

                serde_json::json!({
                    "id": id,
                    "name": name,
                    "location": {
                        "path": path,
                        "line": line,
                        "column": column,
                    }
                })
            })
            .collect(),
        None => Vec::new(),
    };

    (true, serde_json::json!({"frames": frames}))
}

/// Formats a backend `ct/load-flow` response into the simplified
/// `ct/py-flow` response body.
///
/// The backend returns flow/omniscience data containing:
/// - `steps`: array of execution steps, each with `line`, `ticks`, `loopId`,
///   `iteration`, `beforeValues` (dict), and `afterValues` (dict).
/// - `loops`: array of detected loops, each with `id`, `startLine`,
///   `endLine`, and `iterationCount`.
///
/// This function passes through the steps and loops arrays directly,
/// preserving the backend's field names for the Python client to parse.
///
/// Returns `(success, body_or_error)`:
/// - On success: `(true, json!({"steps": [...], "loops": [...]}))`
/// - On failure: `(false, json!({"message": "..."}))`
pub fn format_flow_response(backend_response: &Value) -> (bool, Value) {
    let success = backend_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if !success {
        let message = backend_response
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("load-flow failed");
        return (false, serde_json::json!({"message": message}));
    }

    let body = backend_response
        .get("body")
        .unwrap_or(&Value::Null);

    let steps = body
        .get("steps")
        .cloned()
        .unwrap_or_else(|| serde_json::json!([]));

    let loops = body
        .get("loops")
        .cloned()
        .unwrap_or_else(|| serde_json::json!([]));

    (true, serde_json::json!({"steps": steps, "loops": loops}))
}

// ---------------------------------------------------------------------------
// Method mapping
// ---------------------------------------------------------------------------

/// Maps Python navigation method names to their corresponding DAP commands.
///
/// Returns `(dap_command, is_custom)` where `is_custom` indicates whether
/// the command uses a CodeTracer extension (`ct/*`) rather than standard DAP.
///
/// # Supported methods
///
/// | Python method       | DAP command         | Custom? |
/// |---------------------|---------------------|---------|
/// | `step_over`         | `next`              | no      |
/// | `step_in`           | `stepIn`            | no      |
/// | `step_out`          | `stepOut`           | no      |
/// | `step_back`         | `stepBack`          | no      |
/// | `reverse_step_in`   | `ct/reverseStepIn`  | yes     |
/// | `reverse_step_out`  | `ct/reverseStepOut` | yes     |
/// | `continue_forward`  | `continue`          | no      |
/// | `continue_reverse`  | `reverseContinue`   | no      |
/// | `goto_ticks`        | `ct/goto-ticks`     | yes     |
///
/// Returns `None` for unrecognized method names.
pub fn method_to_dap_command(method: &str) -> Option<(&str, bool)> {
    match method {
        "step_over" => Some(("next", false)),
        "step_in" => Some(("stepIn", false)),
        "step_out" => Some(("stepOut", false)),
        "step_back" => Some(("stepBack", false)),
        "reverse_step_in" => Some(("ct/reverseStepIn", true)),
        "reverse_step_out" => Some(("ct/reverseStepOut", true)),
        "continue_forward" => Some(("continue", false)),
        "continue_reverse" => Some(("reverseContinue", false)),
        "goto_ticks" => Some(("ct/goto-ticks", true)),
        _ => None,
    }
}

/// Extracts a location object (path, line, column, ticks, endOfTrace) from
/// a DAP `stackTrace` response.
///
/// The `stackTrace` response body contains a `stackFrames` array; we use
/// the top frame (index 0) to extract:
/// - `source.path` -> `path`
/// - `line` -> `line`
/// - `column` -> `column`
/// - `ticks` -> `ticks` (CodeTracer extension)
/// - `endOfTrace` -> `endOfTrace` (CodeTracer extension)
///
/// If the response is malformed or has no frames, returns a fallback
/// location with empty/zero values.
pub fn extract_location_from_stack_trace(msg: &Value) -> Value {
    let body = msg.get("body").unwrap_or(&Value::Null);
    let frames = body.get("stackFrames").and_then(Value::as_array);

    if let Some(frames) = frames
        && let Some(top_frame) = frames.first()
    {
        let path = top_frame
            .get("source")
            .and_then(|s| s.get("path"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let line = top_frame.get("line").and_then(Value::as_i64).unwrap_or(0);
        let column = top_frame
            .get("column")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let ticks = top_frame
            .get("ticks")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let end_of_trace = top_frame
            .get("endOfTrace")
            .and_then(Value::as_bool)
            .unwrap_or(false);

        return serde_json::json!({
            "path": path,
            "line": line,
            "column": column,
            "ticks": ticks,
            "endOfTrace": end_of_trace,
        });
    }

    // Fallback: empty location when the response is missing or malformed.
    serde_json::json!({
        "path": "",
        "line": 0,
        "column": 0,
        "ticks": 0,
        "endOfTrace": false,
    })
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_method_to_dap_command_known_methods() {
        assert_eq!(method_to_dap_command("step_over"), Some(("next", false)));
        assert_eq!(method_to_dap_command("step_in"), Some(("stepIn", false)));
        assert_eq!(method_to_dap_command("step_out"), Some(("stepOut", false)));
        assert_eq!(method_to_dap_command("step_back"), Some(("stepBack", false)));
        assert_eq!(
            method_to_dap_command("reverse_step_in"),
            Some(("ct/reverseStepIn", true))
        );
        assert_eq!(
            method_to_dap_command("reverse_step_out"),
            Some(("ct/reverseStepOut", true))
        );
        assert_eq!(
            method_to_dap_command("continue_forward"),
            Some(("continue", false))
        );
        assert_eq!(
            method_to_dap_command("continue_reverse"),
            Some(("reverseContinue", false))
        );
        assert_eq!(
            method_to_dap_command("goto_ticks"),
            Some(("ct/goto-ticks", true))
        );
    }

    #[test]
    fn test_method_to_dap_command_unknown() {
        assert_eq!(method_to_dap_command("unknown_method"), None);
        assert_eq!(method_to_dap_command(""), None);
    }

    #[test]
    fn test_extract_location_from_stack_trace_normal() {
        let msg = json!({
            "type": "response",
            "command": "stackTrace",
            "body": {
                "stackFrames": [{
                    "id": 0,
                    "name": "main",
                    "source": {"path": "main.nim"},
                    "line": 42,
                    "column": 5,
                    "ticks": 12345,
                    "endOfTrace": false,
                }]
            }
        });

        let loc = extract_location_from_stack_trace(&msg);
        assert_eq!(loc["path"], "main.nim");
        assert_eq!(loc["line"], 42);
        assert_eq!(loc["column"], 5);
        assert_eq!(loc["ticks"], 12345);
        assert_eq!(loc["endOfTrace"], false);
    }

    #[test]
    fn test_extract_location_from_stack_trace_end_of_trace() {
        let msg = json!({
            "type": "response",
            "command": "stackTrace",
            "body": {
                "stackFrames": [{
                    "id": 0,
                    "name": "main",
                    "source": {"path": "main.nim"},
                    "line": 100,
                    "column": 1,
                    "ticks": 99999,
                    "endOfTrace": true,
                }]
            }
        });

        let loc = extract_location_from_stack_trace(&msg);
        assert_eq!(loc["endOfTrace"], true);
        assert_eq!(loc["ticks"], 99999);
    }

    #[test]
    fn test_extract_location_from_stack_trace_empty_frames() {
        let msg = json!({
            "type": "response",
            "command": "stackTrace",
            "body": {
                "stackFrames": []
            }
        });

        let loc = extract_location_from_stack_trace(&msg);
        assert_eq!(loc["path"], "");
        assert_eq!(loc["line"], 0);
        assert_eq!(loc["ticks"], 0);
        assert_eq!(loc["endOfTrace"], false);
    }

    #[test]
    fn test_extract_location_from_stack_trace_no_body() {
        let msg = json!({
            "type": "response",
            "command": "stackTrace",
        });

        let loc = extract_location_from_stack_trace(&msg);
        assert_eq!(loc["path"], "");
        assert_eq!(loc["line"], 0);
    }

    #[test]
    fn test_py_bridge_state_seq_counter() {
        let mut state = PyBridgeState::new();
        assert_eq!(state.next_seq(), 1_000_000);
        assert_eq!(state.next_seq(), 1_000_001);
        assert_eq!(state.next_seq(), 1_000_002);
    }

    // --- format_locals_response tests ---

    #[test]
    fn test_format_locals_response_success() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "variables": [
                    {"name": "x", "value": "42", "type": "int", "children": []},
                    {"name": "y", "value": "20", "type": "int", "children": []},
                ]
            }
        });

        let (success, body) = format_locals_response(&backend_resp);
        assert!(success);
        let vars = body["variables"].as_array().expect("variables should be array");
        assert_eq!(vars.len(), 2);
        assert_eq!(vars[0]["name"], "x");
        assert_eq!(vars[0]["value"], "42");
        assert_eq!(vars[1]["name"], "y");
    }

    #[test]
    fn test_format_locals_response_failure() {
        let backend_resp = json!({
            "type": "response",
            "success": false,
            "message": "no locals available"
        });

        let (success, body) = format_locals_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "no locals available");
    }

    #[test]
    fn test_format_locals_response_missing_body() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
        });

        let (success, body) = format_locals_response(&backend_resp);
        assert!(success);
        let vars = body["variables"].as_array().expect("variables should be array");
        assert!(vars.is_empty());
    }

    // --- format_evaluate_response tests ---

    #[test]
    fn test_format_evaluate_response_success() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "result": "42",
                "type": "int",
            }
        });

        let (success, body) = format_evaluate_response(&backend_resp);
        assert!(success);
        assert_eq!(body["result"], "42");
        assert_eq!(body["type"], "int");
    }

    #[test]
    fn test_format_evaluate_response_failure() {
        let backend_resp = json!({
            "type": "response",
            "success": false,
            "message": "cannot evaluate: foo"
        });

        let (success, body) = format_evaluate_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "cannot evaluate: foo");
    }

    // --- format_stack_trace_response tests ---

    #[test]
    fn test_format_stack_trace_response_success() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "stackFrames": [
                    {
                        "id": 0,
                        "name": "main",
                        "source": {"path": "main.nim"},
                        "line": 42,
                        "column": 1,
                    },
                    {
                        "id": 1,
                        "name": "helper",
                        "source": {"path": "helpers.nim"},
                        "line": 10,
                        "column": 5,
                    },
                ],
                "totalFrames": 2,
            }
        });

        let (success, body) = format_stack_trace_response(&backend_resp);
        assert!(success);
        let frames = body["frames"].as_array().expect("frames should be array");
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0]["name"], "main");
        assert_eq!(frames[0]["location"]["path"], "main.nim");
        assert_eq!(frames[0]["location"]["line"], 42);
        assert_eq!(frames[1]["name"], "helper");
        assert_eq!(frames[1]["location"]["path"], "helpers.nim");
    }

    #[test]
    fn test_format_stack_trace_response_failure() {
        let backend_resp = json!({
            "type": "response",
            "success": false,
            "message": "stack trace unavailable"
        });

        let (success, body) = format_stack_trace_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "stack trace unavailable");
    }

    #[test]
    fn test_format_stack_trace_response_empty_frames() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "stackFrames": [],
                "totalFrames": 0,
            }
        });

        let (success, body) = format_stack_trace_response(&backend_resp);
        assert!(success);
        let frames = body["frames"].as_array().expect("frames should be array");
        assert!(frames.is_empty());
    }

    // --- BreakpointState tests ---

    #[test]
    fn test_breakpoint_state_add_and_remove() {
        let mut state = BreakpointState::default();

        // Add two breakpoints in the same file.
        let (bp1, lines1) = state.add_breakpoint("main.nim", 10);
        assert_eq!(bp1, 1);
        assert_eq!(lines1, vec![10]);

        let (bp2, lines2) = state.add_breakpoint("main.nim", 20);
        assert_eq!(bp2, 2);
        assert!(lines2.contains(&10));
        assert!(lines2.contains(&20));

        // Remove the first breakpoint.
        let result = state.remove_breakpoint(bp1);
        assert!(result.is_some());
        let (file, remaining) = result.unwrap();
        assert_eq!(file, "main.nim");
        assert_eq!(remaining, vec![20]);

        // Removing a nonexistent ID returns None.
        assert!(state.remove_breakpoint(999).is_none());
    }

    #[test]
    fn test_breakpoint_state_multiple_files() {
        let mut state = BreakpointState::default();

        let (bp1, _) = state.add_breakpoint("main.nim", 10);
        let (_bp2, _) = state.add_breakpoint("helpers.nim", 5);
        let (_bp3, _) = state.add_breakpoint("main.nim", 30);

        // Only main.nim lines should be returned.
        let main_lines = state.breakpoints_for_file("main.nim");
        assert!(main_lines.contains(&10));
        assert!(main_lines.contains(&30));
        assert_eq!(main_lines.len(), 2);

        let helper_lines = state.breakpoints_for_file("helpers.nim");
        assert_eq!(helper_lines, vec![5]);

        // Remove bp1 (main.nim:10); helpers.nim should be unaffected.
        state.remove_breakpoint(bp1);
        assert_eq!(state.breakpoints_for_file("main.nim"), vec![30]);
        assert_eq!(state.breakpoints_for_file("helpers.nim"), vec![5]);
    }

    #[test]
    fn test_watchpoint_state_add_and_remove() {
        let mut state = BreakpointState::default();

        let (wp1, all1) = state.add_watchpoint("counter");
        assert_eq!(wp1, 1);
        assert_eq!(all1, vec!["counter".to_string()]);

        let (wp2, all2) = state.add_watchpoint("total");
        assert_eq!(wp2, 2);
        assert!(all2.contains(&"counter".to_string()));
        assert!(all2.contains(&"total".to_string()));

        // Remove the first watchpoint.
        let remaining = state.remove_watchpoint(wp1);
        assert!(remaining.is_some());
        assert_eq!(remaining.unwrap(), vec!["total".to_string()]);

        // Removing nonexistent ID returns None.
        assert!(state.remove_watchpoint(999).is_none());
    }

    #[test]
    fn test_py_bridge_state_breakpoint_state_lazy_creation() {
        let mut state = PyBridgeState::new();
        let trace_path = PathBuf::from("/traces/my-trace");

        // First access creates the state.
        let bp_state = state.breakpoint_state_mut(&trace_path);
        let (bp_id, _) = bp_state.add_breakpoint("main.nim", 10);
        assert_eq!(bp_id, 1);

        // Subsequent access returns the same state.
        let bp_state2 = state.breakpoint_state_mut(&trace_path);
        assert_eq!(bp_state2.breakpoints_for_file("main.nim"), vec![10]);
    }

    // --- format_flow_response tests ---

    #[test]
    fn test_format_flow_response_success() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "steps": [
                    {
                        "line": 10, "ticks": 100, "loopId": 1, "iteration": 0,
                        "beforeValues": {"i": "0"}, "afterValues": {"x": "0"}
                    },
                    {
                        "line": 10, "ticks": 110, "loopId": 1, "iteration": 1,
                        "beforeValues": {"i": "1"}, "afterValues": {"x": "2"}
                    },
                ],
                "loops": [
                    {"id": 1, "startLine": 8, "endLine": 12, "iterationCount": 2}
                ],
                "finished": true,
            }
        });

        let (success, body) = format_flow_response(&backend_resp);
        assert!(success);

        let steps = body["steps"].as_array().expect("steps should be array");
        assert_eq!(steps.len(), 2);
        assert_eq!(steps[0]["line"], 10);
        assert_eq!(steps[0]["beforeValues"]["i"], "0");
        assert_eq!(steps[0]["afterValues"]["x"], "0");
        assert_eq!(steps[1]["iteration"], 1);

        let loops = body["loops"].as_array().expect("loops should be array");
        assert_eq!(loops.len(), 1);
        assert_eq!(loops[0]["id"], 1);
        assert_eq!(loops[0]["iterationCount"], 2);
    }

    #[test]
    fn test_format_flow_response_failure() {
        let backend_resp = json!({
            "type": "response",
            "success": false,
            "message": "flow data unavailable"
        });

        let (success, body) = format_flow_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "flow data unavailable");
    }

    #[test]
    fn test_format_flow_response_missing_body() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
        });

        let (success, body) = format_flow_response(&backend_resp);
        assert!(success);
        let steps = body["steps"].as_array().expect("steps should be array");
        assert!(steps.is_empty());
        let loops = body["loops"].as_array().expect("loops should be array");
        assert!(loops.is_empty());
    }
}
