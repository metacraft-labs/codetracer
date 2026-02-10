//! DAP initialization sequence for freshly-started backends.
//!
//! When the daemon opens a trace via `ct/open-trace`, it spawns a backend
//! process and needs to run the standard DAP initialization handshake
//! before the session is ready for queries:
//!
//! 1. **initialize** — negotiate capabilities
//! 2. **launch** — tell the backend which trace to load
//! 3. **configurationDone** — signal that the client is ready
//!
//! After `configurationDone`, the backend sends a `stopped` event
//! indicating it has loaded the trace and is ready for navigation
//! commands.
//!
//! This module encapsulates that handshake so that the daemon's
//! command handlers stay focused on session management rather than
//! DAP protocol details.
//!
//! # References
//!
//! - DAP specification: <https://microsoft.github.io/debug-adapter-protocol/specification>

use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Result of a successful DAP initialization sequence.
///
/// The fields are public so callers (e.g. future MCP server layers) can
/// inspect capabilities or the stopped event.  Currently the `ct/open-trace`
/// handler only checks for success/failure.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct DapInitResult {
    /// The capabilities object returned by the backend's `initialize` response.
    pub capabilities: Value,

    /// The `stopped` event sent by the backend after `configurationDone`.
    pub stopped_event: Value,
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Errors that can occur during the DAP initialization sequence.
#[derive(Debug)]
pub enum DapInitError {
    /// Timed out waiting for a response or event from the backend.
    Timeout {
        /// Which step of the init sequence timed out.
        step: &'static str,
    },
    /// The backend channel was closed unexpectedly.
    ChannelClosed { step: &'static str },
    /// The backend returned an error response.
    BackendError { step: &'static str, message: String },
    /// Failed to send a message to the backend.
    SendFailed { step: &'static str },
}

impl std::fmt::Display for DapInitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Timeout { step } => write!(f, "DAP init timed out at step: {step}"),
            Self::ChannelClosed { step } => {
                write!(f, "backend channel closed during DAP init at step: {step}")
            }
            Self::BackendError { step, message } => {
                write!(f, "backend error at step {step}: {message}")
            }
            Self::SendFailed { step } => {
                write!(f, "failed to send DAP message at step: {step}")
            }
        }
    }
}

impl std::error::Error for DapInitError {}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Sends a DAP request through the channel.
fn send_request(
    sender: &UnboundedSender<Value>,
    command: &str,
    seq: i64,
    arguments: Value,
    step: &'static str,
) -> Result<(), DapInitError> {
    let msg = json!({
        "type": "request",
        "command": command,
        "seq": seq,
        "arguments": arguments,
    });

    sender
        .send(msg)
        .map_err(|_| DapInitError::SendFailed { step })
}

/// Waits for a DAP response with the given `command` field, within the
/// specified timeout.
///
/// Messages that are not responses (e.g. events) are collected in the
/// `events_out` vector so that the caller can inspect them after the
/// sequence completes.
async fn wait_for_response(
    receiver: &mut UnboundedReceiver<Value>,
    expected_command: &str,
    timeout_duration: Duration,
    step: &'static str,
    events_out: &mut Vec<Value>,
) -> Result<Value, DapInitError> {
    let deadline = tokio::time::Instant::now() + timeout_duration;

    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(DapInitError::Timeout { step });
        }

        let msg = tokio::time::timeout(remaining, receiver.recv())
            .await
            .map_err(|_| DapInitError::Timeout { step })?
            .ok_or(DapInitError::ChannelClosed { step })?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");

        match msg_type {
            "response" => {
                let cmd = msg.get("command").and_then(Value::as_str).unwrap_or("");
                if cmd == expected_command {
                    // Check if the response indicates an error.
                    let success = msg.get("success").and_then(Value::as_bool).unwrap_or(true);
                    if !success {
                        let error_msg = msg
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown error")
                            .to_string();
                        return Err(DapInitError::BackendError {
                            step,
                            message: error_msg,
                        });
                    }
                    return Ok(msg);
                }
                // Response for a different command — unusual but not fatal.
                // Collect it with events.
                log::warn!(
                    "DAP init: unexpected response for '{cmd}' while waiting for '{expected_command}'"
                );
                events_out.push(msg);
            }
            "event" => {
                events_out.push(msg);
            }
            _ => {
                // Unknown message type — collect it.
                events_out.push(msg);
            }
        }
    }
}

/// Waits for a `stopped` event within the given timeout.
///
/// Consumes any non-stopped events or responses that arrive before it.
async fn wait_for_stopped_event(
    receiver: &mut UnboundedReceiver<Value>,
    timeout_duration: Duration,
    step: &'static str,
    events_out: &mut Vec<Value>,
) -> Result<Value, DapInitError> {
    let deadline = tokio::time::Instant::now() + timeout_duration;

    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(DapInitError::Timeout { step });
        }

        let msg = tokio::time::timeout(remaining, receiver.recv())
            .await
            .map_err(|_| DapInitError::Timeout { step })?
            .ok_or(DapInitError::ChannelClosed { step })?;

        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");

        if msg_type == "event" {
            let event_name = msg.get("event").and_then(Value::as_str).unwrap_or("");
            if event_name == "stopped" {
                return Ok(msg);
            }
        }

        // Not the stopped event — collect it and keep waiting.
        events_out.push(msg);
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Runs the DAP initialization sequence on a freshly-started backend.
///
/// Sends: `initialize` -> `launch` -> `configurationDone`
/// Waits for: each response and the initial `stopped` event.
///
/// The `trace_folder` is passed to the `launch` request's `arguments`
/// so the backend knows which trace to load.
///
/// The `timeout` duration is applied to each individual wait step (not
/// the total sequence), so the maximum wall-clock time is approximately
/// `4 * timeout`.
///
/// # Errors
///
/// Returns [`DapInitError`] if any step times out, the backend returns
/// an error, or the channel is closed unexpectedly.
pub async fn run_dap_init(
    sender: &UnboundedSender<Value>,
    receiver: &mut UnboundedReceiver<Value>,
    trace_folder: &Path,
    timeout: Duration,
) -> Result<DapInitResult, DapInitError> {
    let mut collected_events: Vec<Value> = Vec::new();

    // Step 1: initialize
    send_request(sender, "initialize", 1, json!({}), "initialize-send")?;

    let init_response = wait_for_response(
        receiver,
        "initialize",
        timeout,
        "initialize-response",
        &mut collected_events,
    )
    .await?;

    // Extract capabilities from the response body (or the response itself
    // if the backend returns them at the top level).
    let capabilities = init_response
        .get("body")
        .cloned()
        .unwrap_or(Value::Object(serde_json::Map::new()));

    // Step 2: launch
    let trace_folder_str = trace_folder.to_string_lossy().to_string();
    send_request(
        sender,
        "launch",
        2,
        json!({
            "traceFolder": trace_folder_str,
            "program": "main",
            "pid": std::process::id(),
        }),
        "launch-send",
    )?;

    wait_for_response(
        receiver,
        "launch",
        timeout,
        "launch-response",
        &mut collected_events,
    )
    .await?;

    // Step 3: configurationDone
    send_request(
        sender,
        "configurationDone",
        3,
        json!({}),
        "configurationDone-send",
    )?;

    wait_for_response(
        receiver,
        "configurationDone",
        timeout,
        "configurationDone-response",
        &mut collected_events,
    )
    .await?;

    // Step 4: wait for the stopped event
    // Check if a stopped event was already collected during earlier waits.
    let stopped_event = {
        let mut found = None;
        collected_events.retain(|ev| {
            if found.is_none()
                && ev.get("type").and_then(Value::as_str) == Some("event")
                && ev.get("event").and_then(Value::as_str) == Some("stopped")
            {
                found = Some(ev.clone());
                false // remove from collected
            } else {
                true
            }
        });

        match found {
            Some(ev) => ev,
            None => {
                wait_for_stopped_event(receiver, timeout, "stopped-event", &mut collected_events)
                    .await?
            }
        }
    };

    Ok(DapInitResult {
        capabilities,
        stopped_event,
    })
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;

    /// Helper: creates a channel pair and returns (sender-to-backend, receiver-from-backend,
    /// sender-from-backend, receiver-at-backend).
    fn make_channels() -> (
        UnboundedSender<Value>,
        UnboundedReceiver<Value>,
        UnboundedSender<Value>,
        UnboundedReceiver<Value>,
    ) {
        let (to_backend_tx, to_backend_rx) = mpsc::unbounded_channel();
        let (from_backend_tx, from_backend_rx) = mpsc::unbounded_channel();
        (
            to_backend_tx,
            from_backend_rx,
            from_backend_tx,
            to_backend_rx,
        )
    }

    /// Simulates a backend that responds to the DAP init sequence.
    async fn mock_backend_responder(mut rx: UnboundedReceiver<Value>, tx: UnboundedSender<Value>) {
        // Wait for initialize request.
        let init_req = rx.recv().await.expect("init request");
        let init_seq = init_req.get("seq").and_then(Value::as_i64).unwrap_or(0);
        tx.send(json!({
            "type": "response",
            "command": "initialize",
            "request_seq": init_seq,
            "success": true,
            "body": {
                "supportsConfigurationDoneRequest": true,
            }
        }))
        .unwrap();

        // Wait for launch request.
        let launch_req = rx.recv().await.expect("launch request");
        let launch_seq = launch_req.get("seq").and_then(Value::as_i64).unwrap_or(0);
        tx.send(json!({
            "type": "response",
            "command": "launch",
            "request_seq": launch_seq,
            "success": true,
            "body": {}
        }))
        .unwrap();

        // Wait for configurationDone request.
        let cfg_req = rx.recv().await.expect("configurationDone request");
        let cfg_seq = cfg_req.get("seq").and_then(Value::as_i64).unwrap_or(0);
        tx.send(json!({
            "type": "response",
            "command": "configurationDone",
            "request_seq": cfg_seq,
            "success": true,
            "body": {}
        }))
        .unwrap();

        // Send the stopped event.
        tx.send(json!({
            "type": "event",
            "event": "stopped",
            "body": {
                "reason": "entry",
                "threadId": 1,
            }
        }))
        .unwrap();
    }

    #[tokio::test]
    async fn test_run_dap_init_success() {
        let (to_backend_tx, mut from_backend_rx, from_backend_tx, to_backend_rx) = make_channels();

        // Spawn mock backend.
        tokio::spawn(mock_backend_responder(to_backend_rx, from_backend_tx));

        let result = run_dap_init(
            &to_backend_tx,
            &mut from_backend_rx,
            Path::new("/tmp/test-trace"),
            Duration::from_secs(5),
        )
        .await;

        assert!(result.is_ok(), "DAP init should succeed, got: {result:?}");
        let init_result = result.unwrap();

        // Check capabilities.
        assert_eq!(
            init_result
                .capabilities
                .get("supportsConfigurationDoneRequest")
                .and_then(Value::as_bool),
            Some(true),
        );

        // Check stopped event.
        assert_eq!(
            init_result
                .stopped_event
                .get("event")
                .and_then(Value::as_str),
            Some("stopped"),
        );
    }

    #[tokio::test]
    async fn test_run_dap_init_timeout() {
        let (to_backend_tx, mut from_backend_rx, _from_backend_tx, _to_backend_rx) =
            make_channels();

        // Don't spawn a responder — the init sequence should time out.
        let result = run_dap_init(
            &to_backend_tx,
            &mut from_backend_rx,
            Path::new("/tmp/test-trace"),
            Duration::from_millis(100),
        )
        .await;

        assert!(result.is_err(), "DAP init should time out");
        match result.unwrap_err() {
            DapInitError::Timeout { step } => {
                assert_eq!(step, "initialize-response");
            }
            other => panic!("expected Timeout, got: {other}"),
        }
    }

    #[tokio::test]
    async fn test_run_dap_init_backend_error() {
        let (to_backend_tx, mut from_backend_rx, from_backend_tx, mut to_backend_rx) =
            make_channels();

        // Spawn a mock that returns an error for initialize.
        tokio::spawn(async move {
            let init_req = to_backend_rx.recv().await.expect("init request");
            let init_seq = init_req.get("seq").and_then(Value::as_i64).unwrap_or(0);
            from_backend_tx
                .send(json!({
                    "type": "response",
                    "command": "initialize",
                    "request_seq": init_seq,
                    "success": false,
                    "message": "unsupported protocol version",
                }))
                .unwrap();
        });

        let result = run_dap_init(
            &to_backend_tx,
            &mut from_backend_rx,
            Path::new("/tmp/test-trace"),
            Duration::from_secs(5),
        )
        .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            DapInitError::BackendError { step, message } => {
                assert_eq!(step, "initialize-response");
                assert!(message.contains("unsupported protocol version"));
            }
            other => panic!("expected BackendError, got: {other}"),
        }
    }

    #[tokio::test]
    async fn test_run_dap_init_channel_closed() {
        let (to_backend_tx, mut from_backend_rx, from_backend_tx, _to_backend_rx) = make_channels();

        // Drop the sender immediately to simulate channel closure.
        drop(from_backend_tx);

        let result = run_dap_init(
            &to_backend_tx,
            &mut from_backend_rx,
            Path::new("/tmp/test-trace"),
            Duration::from_secs(5),
        )
        .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            DapInitError::ChannelClosed { .. } => {}
            other => panic!("expected ChannelClosed, got: {other}"),
        }
    }
}
