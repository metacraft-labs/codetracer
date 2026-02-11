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
    /// RR ticks value captured from the `ct/complete-move` event.
    ///
    /// The standard DAP `stackTrace` response does not include ticks
    /// information.  However, the CodeTracer backend emits a
    /// `ct/complete-move` event (between the `stopped` event and the
    /// `stackTrace` response) that contains `rrTicks` in its
    /// `body.location` field.  We capture it here so it can be injected
    /// into the final `ct/py-navigate` response.
    pub rr_ticks: Option<i64>,
    /// Whether the trace has reached its end, captured from `ct/notification`
    /// events.
    ///
    /// The CodeTracer backend emits `ct/notification` events with text
    /// containing "End of record" or "Limit of record" when the trace
    /// replay reaches its boundary.  We capture this here so it can be
    /// injected as `endOfTrace: true` in the final response.
    pub end_of_trace: bool,
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
    /// `ct/py-calltrace` -> backend `ct/load-calltrace-section`.
    Calltrace,
    /// `ct/py-search-calltrace` -> backend `ct/search-calltrace`.
    SearchCalltrace,
    /// `ct/py-events` -> backend `ct/event-load`.
    Events,
    /// `ct/py-terminal` -> backend `ct/load-terminal`.
    Terminal,
    /// `ct/py-read-source` -> backend `ct/read-source`.
    ReadSource,
    /// `ct/py-processes` -> backend `ct/list-processes`.
    Processes,
    /// `ct/py-select-process` -> backend `ct/select-replay`.
    SelectProcess,
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
/// The real backend (db-backend) returns locals as `body.locals`, an
/// array of `{expression, value, address}` objects where `expression`
/// is the variable name and `value` is a CodeTracer `Value` object
/// containing `i` (the string representation) and `typ` (with
/// `langType`).
///
/// The mock backend (used in daemon integration tests) returns locals
/// as `body.variables` with a simpler `{name, value, type, children}`
/// schema where `value` is already a plain string.
///
/// This function normalises each entry into the simplified
/// `{name, value, type}` schema expected by the Python client,
/// handling both formats:
/// - `name`  = backend's `expression` (or `name` for mock)
/// - `value` = backend's `value.i` (or plain `value` for mock)
/// - `type`  = backend's `value.typ.langType` (or plain `type` for mock)
/// - `children` = preserved from the original if present
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

    // The real backend uses `body.locals`; the mock uses `body.variables`.
    // Try `locals` first, fall back to `variables`.
    let locals_raw = backend_response
        .get("body")
        .and_then(|b| b.get("locals").or_else(|| b.get("variables")));

    let variables: Vec<Value> = match locals_raw.and_then(Value::as_array) {
        Some(arr) => arr.iter().map(normalise_variable).collect(),
        None => Vec::new(),
    };

    (true, serde_json::json!({"variables": variables}))
}

/// Extracts the string representation from a CodeTracer Value JSON object.
///
/// The Value struct (defined in `db-backend/src/value.rs`) stores typed data
/// in different fields depending on `kind` (a `TypeKind` enum serialized as u8):
///   - Int (7):     `i` field (string)
///   - Float (8):   `f` field (string)
///   - String (9):  `text` field
///   - CString (10): `cText` field (camelCase from `c_text`)
///   - Char (11):   `c` field
///   - Bool (12):   `b` field (JSON bool)
///   - Raw (16):    `r` field
///
/// If `val_obj` is a plain JSON string (mock format), returns that directly.
fn extract_value_str(val_obj: Option<&Value>) -> String {
    let v = match val_obj {
        Some(v) if v.is_object() => v,
        // Plain string value (mock format).
        Some(v) => return v.as_str().unwrap_or("").to_string(),
        None => return String::new(),
    };

    let kind = v.get("kind").and_then(Value::as_u64).unwrap_or(u64::MAX);
    match kind {
        7 => str_field(v, "i"),      // Int
        8 => str_field(v, "f"),      // Float
        9 => str_field(v, "text"),   // String
        10 => str_field(v, "cText"), // CString
        11 => str_field(v, "c"),     // Char
        12 => {
            // Bool: the `b` field is a JSON bool, not a string.
            match v.get("b").and_then(Value::as_bool) {
                Some(true) => "true".to_string(),
                _ => "false".to_string(),
            }
        }
        16 => str_field(v, "r"), // Raw
        _ => {
            // Unknown or composite kind: try common value fields as fallback.
            for field in &["i", "f", "text", "r"] {
                let s = str_field(v, field);
                if !s.is_empty() {
                    return s;
                }
            }
            String::new()
        }
    }
}

/// Helper: extracts a string field from a JSON object, returning "" if absent.
fn str_field(v: &Value, field: &str) -> String {
    v.get(field)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

/// Normalises a single variable entry from either the real backend
/// format (`{expression, value: {kind, i, f, ..., typ: {langType}}, address}`)
/// or the simplified mock format (`{name, value, type, children}`).
///
/// Returns a JSON object with `{name, value, type}` and optionally
/// `children` (recursively normalised).
fn normalise_variable(local: &Value) -> Value {
    // Normalise name: real backend uses `expression`, mock uses `name`.
    let name = local
        .get("expression")
        .or_else(|| local.get("name"))
        .and_then(Value::as_str)
        .unwrap_or("");

    // The real backend's `value` is a complex CodeTracer Value object
    // with typed fields (`i`, `f`, `b`, `text`, etc.) and `typ.langType`.
    // The mock's `value` is a plain string.
    let val_obj = local.get("value");
    let value_str = extract_value_str(val_obj);
    let type_str = val_obj
        .and_then(|v| v.get("typ"))
        .and_then(|t| t.get("langType"))
        .and_then(Value::as_str)
        // Fall back to `type` if the value is already simplified (mock format).
        .or_else(|| local.get("type").and_then(Value::as_str))
        .unwrap_or("");

    // Preserve children if present (used by the depth-limit feature).
    // Recursively normalise each child variable.
    let mut result = serde_json::json!({
        "name": name,
        "value": value_str,
        "type": type_str,
    });

    if let Some(children_arr) = local.get("children").and_then(Value::as_array) {
        let normalised_children: Vec<Value> = children_arr.iter().map(normalise_variable).collect();
        result["children"] = serde_json::json!(normalised_children);
    }

    result
}

/// Formats a backend `ct/load-locals` response into the simplified
/// `ct/py-evaluate` response.
///
/// Since the backend does not support the standard DAP `evaluate`
/// command, expression evaluation is implemented by sending a
/// `ct/load-locals` request with the expression in `watchExpressions`.
/// The backend returns all locals (and possibly watch results), and
/// this function extracts the first variable and formats it as
/// `{result, type}`.
///
/// Watch expressions that could not be resolved are marked with an
/// empty value string; this function treats those as evaluation
/// failures.
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

    // The response is from ct/load-locals, which returns body.locals
    // (real backend) or body.variables (mock).
    let locals_raw = backend_response
        .get("body")
        .and_then(|b| b.get("locals").or_else(|| b.get("variables")));

    let first_local = locals_raw
        .and_then(Value::as_array)
        .and_then(|arr| arr.first());

    match first_local {
        Some(local) => {
            // Check for the watch-error sentinel: the mock backend
            // marks unresolvable expressions with `_watch_error: true`
            // and an empty value string.
            let is_watch_error = local
                .get("_watch_error")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if is_watch_error {
                let expr_name = local
                    .get("name")
                    .or_else(|| local.get("expression"))
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                return (
                    false,
                    serde_json::json!({"message": format!("cannot evaluate: {expr_name}")}),
                );
            }

            // Extract the string representation.  The real backend
            // uses a complex CodeTracer Value object with typed fields
            // (`i`, `f`, `b`, `text`, etc.) and `typ.langType`.
            // The mock uses plain strings.
            let val_obj = local.get("value");
            let result_str = extract_value_str(val_obj);
            let type_str = val_obj
                .and_then(|v| v.get("typ"))
                .and_then(|t| t.get("langType"))
                .and_then(Value::as_str)
                .or_else(|| local.get("type").and_then(Value::as_str))
                .unwrap_or("");

            (
                true,
                serde_json::json!({"result": result_str, "type": type_str}),
            )
        }
        None => {
            // No locals found — the expression could not be resolved.
            (
                false,
                serde_json::json!({"message": "no variables found at current location"}),
            )
        }
    }
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

    let body = backend_response.get("body").unwrap_or(&Value::Null);
    let frames_raw = body.get("stackFrames").and_then(Value::as_array);

    let frames: Vec<Value> = match frames_raw {
        Some(arr) => arr
            .iter()
            .map(|frame| {
                let id = frame.get("id").and_then(Value::as_i64).unwrap_or(0);
                let name = frame.get("name").and_then(Value::as_str).unwrap_or("");
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

    let body = backend_response.get("body").unwrap_or(&Value::Null);

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

/// Formats a backend `ct/load-calltrace-section` response into the simplified
/// `ct/py-calltrace` response body.
///
/// Extracts the `calls` array from the response body and passes it through.
/// Each call has `id`, `name`, `location`, `returnValue`, `childrenCount`,
/// and `depth`.
///
/// Returns `(success, body_or_error)`:
/// - On success: `(true, json!({"calls": [...]}))`
/// - On failure: `(false, json!({"message": "..."}))`
pub fn format_calltrace_response(backend_response: &Value) -> (bool, Value) {
    let success = backend_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if !success {
        let message = backend_response
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("load-calltrace-section failed");
        return (false, serde_json::json!({"message": message}));
    }

    let calls = backend_response
        .get("body")
        .and_then(|b| b.get("calls"))
        .cloned()
        .unwrap_or_else(|| serde_json::json!([]));

    (true, serde_json::json!({"calls": calls}))
}

/// Formats a backend `ct/search-calltrace` response into the simplified
/// `ct/py-search-calltrace` response body.
///
/// Same format as `format_calltrace_response` — extracts the `calls` array.
///
/// Returns `(success, body_or_error)`:
/// - On success: `(true, json!({"calls": [...]}))`
/// - On failure: `(false, json!({"message": "..."}))`
pub fn format_search_calltrace_response(backend_response: &Value) -> (bool, Value) {
    let success = backend_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if !success {
        let message = backend_response
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("search-calltrace failed");
        return (false, serde_json::json!({"message": message}));
    }

    let calls = backend_response
        .get("body")
        .and_then(|b| b.get("calls"))
        .cloned()
        .unwrap_or_else(|| serde_json::json!([]));

    (true, serde_json::json!({"calls": calls}))
}

/// Formats a backend `ct/event-load` response into the simplified
/// `ct/py-events` response body.
///
/// Extracts the `events` array from the response body. Each event has
/// `id`, `type`, `ticks`, `content`, and `location`.
///
/// Returns `(success, body_or_error)`:
/// - On success: `(true, json!({"events": [...]}))`
/// - On failure: `(false, json!({"message": "..."}))`
pub fn format_events_response(backend_response: &Value) -> (bool, Value) {
    let success = backend_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if !success {
        let message = backend_response
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("event-load failed");
        return (false, serde_json::json!({"message": message}));
    }

    let events = backend_response
        .get("body")
        .and_then(|b| b.get("events"))
        .cloned()
        .unwrap_or_else(|| serde_json::json!([]));

    (true, serde_json::json!({"events": events}))
}

/// Formats a backend `ct/load-terminal` response into the simplified
/// `ct/py-terminal` response body.
///
/// Extracts the `output` string from the response body.
///
/// Returns `(success, body_or_error)`:
/// - On success: `(true, json!({"output": "..."}))`
/// - On failure: `(false, json!({"message": "..."}))`
pub fn format_terminal_response(backend_response: &Value) -> (bool, Value) {
    let success = backend_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if !success {
        let message = backend_response
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("load-terminal failed");
        return (false, serde_json::json!({"message": message}));
    }

    let output = backend_response
        .get("body")
        .and_then(|b| b.get("output"))
        .and_then(Value::as_str)
        .unwrap_or("");

    (true, serde_json::json!({"output": output}))
}

/// Formats a backend `ct/read-source` response into the simplified
/// `ct/py-read-source` response body.
///
/// Extracts the `content` string from the response body.
///
/// Returns `(success, body_or_error)`:
/// - On success: `(true, json!({"content": "..."}))`
/// - On failure: `(false, json!({"message": "..."}))`
pub fn format_read_source_response(backend_response: &Value) -> (bool, Value) {
    let success = backend_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if !success {
        let message = backend_response
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("read-source failed");
        return (false, serde_json::json!({"message": message}));
    }

    let content = backend_response
        .get("body")
        .and_then(|b| b.get("content"))
        .and_then(Value::as_str)
        .unwrap_or("");

    (true, serde_json::json!({"content": content}))
}

/// Formats a backend `ct/list-processes` response into the simplified
/// `ct/py-processes` response body.
///
/// Extracts the `processes` array from the response body.  Each process
/// has `id`, `name`, and `command`.
///
/// Returns `(success, body_or_error)`:
/// - On success: `(true, json!({"processes": [...]}))`
/// - On failure: `(false, json!({"message": "..."}))`
pub fn format_processes_response(backend_response: &Value) -> (bool, Value) {
    let success = backend_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if !success {
        let message = backend_response
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("list-processes failed");
        return (false, serde_json::json!({"message": message}));
    }

    let processes = backend_response
        .get("body")
        .and_then(|b| b.get("processes"))
        .cloned()
        .unwrap_or_else(|| serde_json::json!([]));

    (true, serde_json::json!({"processes": processes}))
}

/// Formats a backend `ct/select-replay` response into the simplified
/// `ct/py-select-process` response body.
///
/// This is a simple success pass-through — the response body is empty
/// on success.
///
/// Returns `(success, body_or_error)`:
/// - On success: `(true, json!({}))`
/// - On failure: `(false, json!({"message": "..."}))`
pub fn format_select_process_response(backend_response: &Value) -> (bool, Value) {
    let success = backend_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if !success {
        let message = backend_response
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("select-replay failed");
        return (false, serde_json::json!({"message": message}));
    }

    (true, serde_json::json!({}))
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
        let column = top_frame.get("column").and_then(Value::as_i64).unwrap_or(0);
        let ticks = top_frame.get("ticks").and_then(Value::as_i64).unwrap_or(0);
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
        assert_eq!(
            method_to_dap_command("step_back"),
            Some(("stepBack", false))
        );
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
    fn test_format_locals_response_success_backend_format() {
        // The real backend returns `locals` with `expression` and a complex
        // `value` object containing `i` (string repr) and `typ.langType`.
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "locals": [
                    {
                        "expression": "x",
                        "value": {"i": "42", "typ": {"langType": "int"}},
                        "address": -1,
                    },
                    {
                        "expression": "y",
                        "value": {"i": "20", "typ": {"langType": "int"}},
                        "address": -1,
                    },
                ]
            }
        });

        let (success, body) = format_locals_response(&backend_resp);
        assert!(success);
        let vars = body["variables"]
            .as_array()
            .expect("variables should be array");
        assert_eq!(vars.len(), 2);
        assert_eq!(vars[0]["name"], "x");
        assert_eq!(vars[0]["value"], "42");
        assert_eq!(vars[0]["type"], "int");
        assert_eq!(vars[1]["name"], "y");
        assert_eq!(vars[1]["value"], "20");
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
        let vars = body["variables"]
            .as_array()
            .expect("variables should be array");
        assert!(vars.is_empty());
    }

    #[test]
    fn test_format_locals_response_fallback_variables_key() {
        // If a future backend uses `variables` instead of `locals`, the
        // formatter should still work.
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "variables": [
                    {"name": "a", "value": "1", "type": "i32"},
                ]
            }
        });

        let (success, body) = format_locals_response(&backend_resp);
        assert!(success);
        let vars = body["variables"]
            .as_array()
            .expect("variables should be array");
        assert_eq!(vars.len(), 1);
        // When `name` is present (not `expression`), it falls through to the
        // `name` fallback.
        assert_eq!(vars[0]["name"], "a");
        // When `value` is a plain string (not an object), it falls through to
        // the plain-string fallback.
        assert_eq!(vars[0]["value"], "1");
    }

    #[test]
    fn test_format_locals_response_preserves_children() {
        // The mock backend returns variables with `children` arrays
        // for nested structures.  The formatter should preserve them.
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "variables": [
                    {
                        "name": "point",
                        "value": "Point{x: 1, y: 2}",
                        "type": "Point",
                        "children": [
                            {"name": "x", "value": "1", "type": "int", "children": []},
                            {"name": "y", "value": "2", "type": "int", "children": []},
                        ]
                    },
                ]
            }
        });

        let (success, body) = format_locals_response(&backend_resp);
        assert!(success);
        let vars = body["variables"]
            .as_array()
            .expect("variables should be array");
        assert_eq!(vars.len(), 1);
        assert_eq!(vars[0]["name"], "point");
        let children = vars[0]["children"]
            .as_array()
            .expect("point should have children");
        assert_eq!(children.len(), 2);
        assert_eq!(children[0]["name"], "x");
        assert_eq!(children[0]["value"], "1");
        assert_eq!(children[1]["name"], "y");
    }

    // --- format_evaluate_response tests ---
    //
    // The evaluate response formatter now handles ct/load-locals
    // responses (body.locals) rather than DAP evaluate responses,
    // because the backend does not support the DAP evaluate command.

    #[test]
    fn test_format_evaluate_response_success_from_locals() {
        // Simulates a ct/load-locals response with a single local
        // variable, which is what the daemon sends when handling
        // ct/py-evaluate.
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "locals": [
                    {
                        "expression": "x",
                        "value": {
                            "i": "42",
                            "typ": { "langType": "int" }
                        },
                        "address": 0
                    }
                ]
            }
        });

        let (success, body) = format_evaluate_response(&backend_resp);
        assert!(success);
        assert_eq!(body["result"], "42");
        assert_eq!(body["type"], "int");
    }

    #[test]
    fn test_format_evaluate_response_no_locals() {
        // When no locals are found, the formatter returns failure.
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "locals": []
            }
        });

        let (success, body) = format_evaluate_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "no variables found at current location");
    }

    #[test]
    fn test_format_evaluate_response_watch_error() {
        // When the mock marks a watch expression as unresolvable
        // via the `_watch_error` sentinel, the formatter should
        // return failure.
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "variables": [
                    {
                        "name": "nonexistent_var",
                        "value": "",
                        "type": "",
                        "children": [],
                        "_watch_error": true
                    }
                ]
            }
        });

        let (success, body) = format_evaluate_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "cannot evaluate: nonexistent_var");
    }

    #[test]
    fn test_format_evaluate_response_mock_variables() {
        // The mock backend returns variables in the simplified
        // {name, value, type, children} format under body.variables.
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "variables": [
                    {"name": "x + y", "value": "30", "type": "int", "children": []},
                    {"name": "x", "value": "42", "type": "int", "children": []},
                ]
            }
        });

        let (success, body) = format_evaluate_response(&backend_resp);
        assert!(success);
        assert_eq!(body["result"], "30");
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

    // --- format_calltrace_response tests ---

    #[test]
    fn test_format_calltrace_response_success() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "calls": [
                    {"id": 0, "name": "main", "location": {"path": "main.nim", "line": 1},
                     "returnValue": "0", "childrenCount": 2, "depth": 0},
                    {"id": 1, "name": "helper", "location": {"path": "helpers.nim", "line": 10},
                     "returnValue": "42", "childrenCount": 0, "depth": 1},
                ]
            }
        });

        let (success, body) = format_calltrace_response(&backend_resp);
        assert!(success);
        let calls = body["calls"].as_array().expect("calls should be array");
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0]["name"], "main");
        assert_eq!(calls[1]["name"], "helper");
    }

    #[test]
    fn test_format_calltrace_response_failure() {
        let backend_resp = json!({
            "type": "response",
            "success": false,
            "message": "calltrace unavailable"
        });

        let (success, body) = format_calltrace_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "calltrace unavailable");
    }

    #[test]
    fn test_format_calltrace_response_missing_body() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
        });

        let (success, body) = format_calltrace_response(&backend_resp);
        assert!(success);
        let calls = body["calls"].as_array().expect("calls should be array");
        assert!(calls.is_empty());
    }

    // --- format_search_calltrace_response tests ---

    #[test]
    fn test_format_search_calltrace_response_success() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "calls": [
                    {"id": 0, "name": "main", "location": {"path": "main.nim", "line": 1}},
                ]
            }
        });

        let (success, body) = format_search_calltrace_response(&backend_resp);
        assert!(success);
        let calls = body["calls"].as_array().expect("calls should be array");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["name"], "main");
    }

    #[test]
    fn test_format_search_calltrace_response_failure() {
        let backend_resp = json!({
            "type": "response",
            "success": false,
            "message": "search failed"
        });

        let (success, body) = format_search_calltrace_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "search failed");
    }

    // --- format_events_response tests ---

    #[test]
    fn test_format_events_response_success() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "events": [
                    {"id": 0, "type": "stdout", "ticks": 100, "content": "Hello\n",
                     "location": {"path": "main.nim", "line": 5, "column": 1}},
                ]
            }
        });

        let (success, body) = format_events_response(&backend_resp);
        assert!(success);
        let events = body["events"].as_array().expect("events should be array");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "stdout");
        assert_eq!(events[0]["content"], "Hello\n");
    }

    #[test]
    fn test_format_events_response_failure() {
        let backend_resp = json!({
            "type": "response",
            "success": false,
            "message": "events unavailable"
        });

        let (success, body) = format_events_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "events unavailable");
    }

    #[test]
    fn test_format_events_response_missing_body() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
        });

        let (success, body) = format_events_response(&backend_resp);
        assert!(success);
        let events = body["events"].as_array().expect("events should be array");
        assert!(events.is_empty());
    }

    // --- format_terminal_response tests ---

    #[test]
    fn test_format_terminal_response_success() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "output": "Hello, World!\nDone.\n"
            }
        });

        let (success, body) = format_terminal_response(&backend_resp);
        assert!(success);
        assert_eq!(body["output"], "Hello, World!\nDone.\n");
    }

    #[test]
    fn test_format_terminal_response_failure() {
        let backend_resp = json!({
            "type": "response",
            "success": false,
            "message": "terminal unavailable"
        });

        let (success, body) = format_terminal_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "terminal unavailable");
    }

    #[test]
    fn test_format_terminal_response_missing_body() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
        });

        let (success, body) = format_terminal_response(&backend_resp);
        assert!(success);
        assert_eq!(body["output"], "");
    }

    // --- format_read_source_response tests ---

    #[test]
    fn test_format_read_source_response_success() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "content": "proc main() =\n  echo \"hello\"\n"
            }
        });

        let (success, body) = format_read_source_response(&backend_resp);
        assert!(success);
        assert_eq!(body["content"], "proc main() =\n  echo \"hello\"\n");
    }

    #[test]
    fn test_format_read_source_response_failure() {
        let backend_resp = json!({
            "type": "response",
            "success": false,
            "message": "file not found"
        });

        let (success, body) = format_read_source_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "file not found");
    }

    #[test]
    fn test_format_read_source_response_missing_body() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
        });

        let (success, body) = format_read_source_response(&backend_resp);
        assert!(success);
        assert_eq!(body["content"], "");
    }

    // --- format_processes_response tests ---

    #[test]
    fn test_format_processes_response_success() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {
                "processes": [
                    {"id": 1, "name": "main", "command": "/usr/bin/prog"},
                    {"id": 2, "name": "child", "command": "/usr/bin/prog --worker"},
                ]
            }
        });

        let (success, body) = format_processes_response(&backend_resp);
        assert!(success);
        let procs = body["processes"]
            .as_array()
            .expect("processes should be array");
        assert_eq!(procs.len(), 2);
        assert_eq!(procs[0]["id"], 1);
        assert_eq!(procs[0]["name"], "main");
        assert_eq!(procs[0]["command"], "/usr/bin/prog");
        assert_eq!(procs[1]["id"], 2);
        assert_eq!(procs[1]["name"], "child");
    }

    #[test]
    fn test_format_processes_response_failure() {
        let backend_resp = json!({
            "type": "response",
            "success": false,
            "message": "process list unavailable"
        });

        let (success, body) = format_processes_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "process list unavailable");
    }

    #[test]
    fn test_format_processes_response_missing_body() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
        });

        let (success, body) = format_processes_response(&backend_resp);
        assert!(success);
        let procs = body["processes"]
            .as_array()
            .expect("processes should be array");
        assert!(procs.is_empty());
    }

    // --- format_select_process_response tests ---

    #[test]
    fn test_format_select_process_response_success() {
        let backend_resp = json!({
            "type": "response",
            "success": true,
            "body": {}
        });

        let (success, body) = format_select_process_response(&backend_resp);
        assert!(success);
        assert!(body.is_object());
    }

    #[test]
    fn test_format_select_process_response_failure() {
        let backend_resp = json!({
            "type": "response",
            "success": false,
            "message": "invalid process ID"
        });

        let (success, body) = format_select_process_response(&backend_resp);
        assert!(!success);
        assert_eq!(body["message"], "invalid process ID");
    }
}
