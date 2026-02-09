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

use serde_json::Value;

// ---------------------------------------------------------------------------
// PyBridgeState
// ---------------------------------------------------------------------------

/// State for tracking active Python bridge navigation operations.
///
/// The daemon holds one `PyBridgeState` instance in its `DaemonState`.
/// Each `ct/py-navigate` request creates a [`PendingPyNavigation`] that
/// progresses through a state machine as DAP messages flow back from
/// the backend.
#[derive(Debug, Default)]
pub struct PyBridgeState {
    /// Pending navigation operations waiting for completion.
    pub pending_navigations: Vec<PendingPyNavigation>,
    /// Counter for generating unique DAP seq numbers for bridge-initiated
    /// requests (e.g., `stackTrace`).  Starts at 1,000,000 to avoid
    /// conflicts with client-originated seq numbers.
    pub next_seq: i64,
}

impl PyBridgeState {
    pub fn new() -> Self {
        Self {
            pending_navigations: Vec::new(),
            next_seq: 1_000_000,
        }
    }

    /// Returns the next unique seq number for bridge-initiated DAP requests.
    pub fn next_seq(&mut self) -> i64 {
        let seq = self.next_seq;
        self.next_seq += 1;
        seq
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
}
