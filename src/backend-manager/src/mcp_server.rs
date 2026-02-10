//! MCP (Model Context Protocol) server for CodeTracer trace querying.
//!
//! Implements the MCP specification (JSON-RPC 2.0 over stdio) to expose
//! trace querying as tools for LLM agents.  The server reads
//! newline-delimited JSON from stdin and writes responses to stdout.
//! All diagnostic logging goes to stderr to avoid corrupting the
//! JSON-RPC transport.
//!
//! # Protocol
//!
//! The server follows the MCP specification (protocol version 2024-11-05):
//! - [MCP Specification](https://spec.modelcontextprotocol.io/)
//! - JSON-RPC 2.0 messages are newline-delimited on stdin/stdout
//! - The `initialize` handshake establishes capabilities
//! - Tools are exposed via `tools/list` and invoked via `tools/call`
//! - Prompts are exposed via `prompts/list` and fetched via `prompts/get`
//!
//! # Architecture
//!
//! The MCP server is a CLIENT of the CodeTracer daemon.  It connects to the
//! daemon's Unix socket (auto-starting the daemon if needed) and sends
//! DAP-framed messages to execute tool operations.  This is the same
//! communication pattern used by the CLI (`ct trace query`, `ct trace info`).

use std::io::BufRead;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

use crate::dap_parser::DapParser;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// MCP protocol version supported by this server.
const PROTOCOL_VERSION: &str = "2024-11-05";

/// Server name reported in the `initialize` response.
const SERVER_NAME: &str = "codetracer-trace-query";

/// Server version reported in the `initialize` response.
const SERVER_VERSION: &str = "0.1.0";

/// Default script execution timeout in seconds.
const DEFAULT_SCRIPT_TIMEOUT: u64 = 30;

// ---------------------------------------------------------------------------
// Tool schemas
// ---------------------------------------------------------------------------

/// Returns the JSON schema for the `exec_script` tool.
fn exec_script_tool() -> Value {
    json!({
        "name": "exec_script",
        "description": "Execute a Python script against a CodeTracer trace file. The script uses the CodeTracer Trace Query API to navigate, inspect, and analyze the recorded program execution. The `trace` variable is pre-bound to the opened trace.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "trace_path": {
                    "type": "string",
                    "description": "Path to the trace file or folder"
                },
                "script": {
                    "type": "string",
                    "description": "Python script to execute. Use `trace` to access the trace API. Print results to stdout."
                },
                "timeout_seconds": {
                    "type": "number",
                    "description": "Maximum execution time in seconds (default: 30)",
                    "default": 30
                }
            },
            "required": ["trace_path", "script"]
        }
    })
}

/// Returns the JSON schema for the `trace_info` tool.
fn trace_info_tool() -> Value {
    json!({
        "name": "trace_info",
        "description": "Get metadata about a CodeTracer trace file: language, event count, source files, and duration.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "trace_path": {
                    "type": "string",
                    "description": "Path to the trace file or folder"
                }
            },
            "required": ["trace_path"]
        }
    })
}

/// Returns the JSON schema for the `list_source_files` tool.
fn list_source_files_tool() -> Value {
    json!({
        "name": "list_source_files",
        "description": "List all source files available in a CodeTracer trace.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "trace_path": {
                    "type": "string",
                    "description": "Path to the trace file or folder"
                }
            },
            "required": ["trace_path"]
        }
    })
}

/// Returns the JSON schema for the `read_source_file` tool.
fn read_source_file_tool() -> Value {
    json!({
        "name": "read_source_file",
        "description": "Read a source file from a CodeTracer trace. Traces include copies of all source files at recording time.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "trace_path": {
                    "type": "string",
                    "description": "Path to the trace file or folder"
                },
                "file_path": {
                    "type": "string",
                    "description": "Path of the source file within the trace"
                }
            },
            "required": ["trace_path", "file_path"]
        }
    })
}

// ---------------------------------------------------------------------------
// Prompt content
// ---------------------------------------------------------------------------

/// Returns the Python API reference text for the `trace_query_api` prompt.
///
/// This is a concise reference covering the data types, Trace class methods,
/// and usage patterns.  It is designed to fit within LLM context windows
/// while providing enough detail for agents to write effective trace queries.
fn trace_query_api_reference() -> &'static str {
    r#"# CodeTracer Trace Query API Reference

## Overview

The Trace Query API allows you to programmatically navigate and inspect
recorded program executions.  A `trace` variable is pre-bound to the
opened trace in every script.

## Data Types

### Location
- `path: str` - Source file path
- `line: int` - Line number (1-based)
- `column: int` - Column number (1-based)
- `ticks: int` - Execution timestamp (monotonic)

### Variable
- `name: str` - Variable name
- `value: str` - String representation of the value
- `type: str` - Type name
- `children: list[Variable]` - Nested fields/elements

### Frame
- `name: str` - Function name
- `location: Location` - Source location
- `index: int` - Frame index (0 = top)

### FlowStep
- `line: int` - Source line
- `ticks: int` - Execution timestamp
- `loop_id: int` - Loop identifier (0 = not in loop)
- `iteration: int` - Loop iteration index
- `before_values: dict[str, str]` - Variable values before step
- `after_values: dict[str, str]` - Variable values after step

### Flow
- `steps: list[FlowStep]` - Execution steps
- `loops: list[Loop]` - Loop information
- `finished: bool` - Whether flow collection completed

### Loop
- `id: int` - Loop identifier
- `start_line: int` - First line of the loop
- `end_line: int` - Last line of the loop
- `iteration_count: int` - Total iterations

### Call
- `id: int` - Call identifier
- `name: str` - Function name
- `location: Location` - Call site location
- `return_value: str | None` - Return value (if available)
- `children_count: int` - Number of child calls
- `depth: int` - Call tree depth

### Event
- `id: int` - Event identifier
- `type: str` - Event type ("stdout", "stderr", etc.)
- `ticks: int` - Execution timestamp
- `content: str` - Event content
- `location: Location` - Source location

### Process
- `id: int` - Process identifier
- `name: str` - Process name
- `command: str` - Command line

## Trace Class

### Properties
- `trace.location -> Location` - Current execution position
- `trace.ticks -> int` - Current execution timestamp
- `trace.source_files -> list[str]` - All source file paths
- `trace.total_events -> int` - Total number of trace events
- `trace.language -> str` - Programming language of the traced program

### Navigation
- `trace.step_over()` - Step to the next line (same scope)
- `trace.step_in()` - Step into function call
- `trace.step_out()` - Step out of current function
- `trace.step_back()` - Step backward one line
- `trace.continue_forward()` - Continue to next breakpoint/end
- `trace.continue_reverse()` - Continue backward to previous breakpoint/start
- `trace.goto_ticks(ticks: int)` - Jump to a specific execution timestamp
- `trace.reverse_step_in()` - Reverse step into
- `trace.reverse_step_out()` - Reverse step out

### Inspection
- `trace.locals(depth: int = 3) -> list[Variable]` - Get local variables
- `trace.evaluate(expr: str) -> Variable` - Evaluate an expression
- `trace.stack_trace() -> list[Frame]` - Get the current call stack

### Breakpoints
- `trace.set_breakpoint(file: str, line: int)` - Set a line breakpoint
- `trace.clear_breakpoints(file: str)` - Remove all breakpoints in a file
- `trace.set_watchpoint(expr: str)` - Watch for variable changes
- `trace.clear_watchpoints()` - Remove all watchpoints

### Flow (Omniscience)
- `trace.flow(file: str, line: int, mode: str = "call") -> Flow`
  - Get execution flow data for a line.
  - `mode="call"`: full function scope.  `mode="line"`: single line.

### Call Trace
- `trace.calltrace(start: int = 0, count: int = 20) -> list[Call]`
  - Get a slice of the call trace.
- `trace.search_calltrace(query: str) -> list[Call]`
  - Search calls by function name.

### Events
- `trace.events(start: int = 0, count: int = 100, type_filter: str | None = None) -> list[Event]`
  - Get I/O and other events.  Optional `type_filter`: "stdout", "stderr".
- `trace.terminal_output() -> str`
  - Get the full terminal output.

### Multi-process
- `trace.processes() -> list[Process]` - List all processes in the trace.
- `trace.select_process(process_id: int)` - Switch to a different process.

### Source Files
- `trace.read_source(file_path: str) -> str` - Read a source file's content.

## Usage Example

```python
# Print current location
print(f"At {trace.location.path}:{trace.location.line}")

# Navigate and inspect
trace.step_over()
for var in trace.locals():
    print(f"  {var.name} = {var.value}")

# Set breakpoint and continue
trace.set_breakpoint("main.py", 42)
trace.continue_forward()

# Get flow data for a line
flow = trace.flow("main.py", 10)
for step in flow.steps:
    print(f"  ticks={step.ticks} {step.after_values}")
```
"#
}

// ---------------------------------------------------------------------------
// DAP communication helpers (async)
// ---------------------------------------------------------------------------

/// Sends a DAP request to the daemon over `stream` and reads the response.
///
/// Skips any interleaved DAP events (type="event") that may arrive before
/// the actual response.  Returns the parsed JSON response.  Times out
/// after `deadline_secs`.
async fn dap_request(
    stream: &mut UnixStream,
    command: &str,
    seq: i64,
    arguments: Value,
    deadline_secs: u64,
) -> Result<Value, String> {
    let request = json!({
        "type": "request",
        "command": command,
        "seq": seq,
        "arguments": arguments,
    });
    let bytes = DapParser::to_bytes(&request);
    stream
        .write_all(&bytes)
        .await
        .map_err(|e| format!("failed to write to daemon: {e}"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(deadline_secs);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(format!("timeout waiting for {command} response"));
        }

        let msg = tokio::time::timeout(remaining, dap_read_message(stream))
            .await
            .map_err(|_| format!("timeout waiting for {command} response"))?
            .map_err(|e| format!("failed to read daemon response: {e}"))?;

        // Skip DAP events — we only want the response.
        let msg_type = msg.get("type").and_then(Value::as_str).unwrap_or("");
        if msg_type == "event" {
            eprintln!(
                "mcp: skipping interleaved DAP event while waiting for {command} response"
            );
            continue;
        }

        return Ok(msg);
    }
}

/// Reads a single DAP-framed JSON message from `stream`.
///
/// Parses the `Content-Length` header, then reads the JSON body.
async fn dap_read_message(stream: &mut UnixStream) -> Result<Value, String> {
    let mut header_buf = Vec::with_capacity(256);
    let mut single = [0u8; 1];

    loop {
        let n = stream
            .read(&mut single)
            .await
            .map_err(|e| format!("read error: {e}"))?;
        if n == 0 {
            return Err("EOF while reading DAP header".to_string());
        }
        header_buf.push(single[0]);
        if header_buf.len() >= 4 && header_buf.ends_with(b"\r\n\r\n") {
            break;
        }
        if header_buf.len() > 8192 {
            return Err("DAP header too large".to_string());
        }
    }

    let header_str = String::from_utf8_lossy(&header_buf);
    let prefix = "Content-Length: ";
    let line = header_str
        .lines()
        .find(|l| l.starts_with(prefix))
        .ok_or("missing Content-Length in DAP header")?;
    let content_length: usize = line[prefix.len()..]
        .trim()
        .parse()
        .map_err(|e| format!("bad Content-Length: {e}"))?;

    let mut body_buf = vec![0u8; content_length];
    stream
        .read_exact(&mut body_buf)
        .await
        .map_err(|e| format!("body read error: {e}"))?;

    serde_json::from_slice(&body_buf).map_err(|e| format!("json parse error: {e}"))
}

// ---------------------------------------------------------------------------
// JSON-RPC helpers
// ---------------------------------------------------------------------------

/// Builds a successful JSON-RPC response.
fn jsonrpc_result(id: &Value, result: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result,
    })
}

/// Builds a JSON-RPC error response.
///
/// Error codes follow the JSON-RPC 2.0 specification:
/// - `-32700`: Parse error
/// - `-32600`: Invalid request
/// - `-32601`: Method not found
/// - `-32602`: Invalid params
/// - `-32603`: Internal error
fn jsonrpc_error(id: &Value, code: i64, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": message,
        },
    })
}

/// Builds an MCP tool result with text content.
fn tool_result_text(text: &str) -> Value {
    json!({
        "content": [{"type": "text", "text": text}],
    })
}

/// Builds an MCP tool result indicating an error (isError: true).
fn tool_result_error(text: &str) -> Value {
    json!({
        "content": [{"type": "text", "text": text}],
        "isError": true,
    })
}

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------

/// Configuration for the MCP server, extracted from environment variables
/// and daemon paths.
pub struct McpServerConfig {
    /// Path to the daemon's Unix socket.
    pub daemon_socket_path: PathBuf,
    /// Path to the daemon's PID file.
    pub daemon_pid_path: PathBuf,
}

/// Runs the MCP server on stdio.
///
/// Reads newline-delimited JSON-RPC messages from stdin and writes
/// responses to stdout.  Connects to the daemon on demand for tool
/// operations.  All logging goes to stderr.
///
/// The `config` parameter provides the daemon socket and PID file paths.
pub async fn run_mcp_server(config: McpServerConfig) -> Result<(), Box<dyn std::error::Error>> {
    let stdin = std::io::stdin();
    let reader = stdin.lock();

    // Process each line from stdin as a JSON-RPC message.
    for line_result in reader.lines() {
        let line = match line_result {
            Ok(l) => l,
            Err(e) => {
                eprintln!("mcp: stdin read error: {e}");
                break;
            }
        };

        let line = line.trim().to_string();
        if line.is_empty() {
            // Blank lines are ignored (not part of JSON-RPC).
            continue;
        }

        // Parse the JSON-RPC message.
        let msg: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("mcp: invalid JSON: {e}");
                // JSON-RPC spec: parse errors get id=null.
                let error = jsonrpc_error(&Value::Null, -32700, &format!("Parse error: {e}"));
                write_jsonrpc_message(&error);
                continue;
            }
        };

        let id = msg.get("id").cloned().unwrap_or(Value::Null);
        let method = msg
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("");

        // Notifications (no id) do not get responses.
        let is_notification = msg.get("id").is_none();

        match method {
            "initialize" => {
                let response = handle_initialize(&id);
                write_jsonrpc_message(&response);
            }
            "notifications/initialized" => {
                // Client acknowledges initialization; nothing to do.
                eprintln!("mcp: client initialized");
            }
            "tools/list" => {
                let response = handle_tools_list(&id);
                write_jsonrpc_message(&response);
            }
            "tools/call" => {
                let params = msg.get("params");
                let response = handle_tools_call(&id, params, &config).await;
                write_jsonrpc_message(&response);
            }
            "prompts/list" => {
                let response = handle_prompts_list(&id);
                write_jsonrpc_message(&response);
            }
            "prompts/get" => {
                let params = msg.get("params");
                let response = handle_prompts_get(&id, params);
                write_jsonrpc_message(&response);
            }
            _ => {
                if !is_notification {
                    let response = jsonrpc_error(
                        &id,
                        -32601,
                        &format!("Method not found: {method}"),
                    );
                    write_jsonrpc_message(&response);
                }
                // Unknown notifications are silently ignored per spec.
            }
        }
    }

    Ok(())
}

/// Writes a single JSON-RPC message to stdout (newline-delimited).
///
/// This function ensures that each message is written atomically as a
/// single line followed by a newline, and stdout is flushed immediately.
/// No other output is written to stdout.
fn write_jsonrpc_message(msg: &Value) {
    // Serialize to a single line (no pretty-printing).
    let serialized = serde_json::to_string(msg).unwrap_or_else(|e| {
        eprintln!("mcp: failed to serialize response: {e}");
        // Return a minimal error response as fallback.
        r#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"serialization error"}}"#
            .to_string()
    });

    // Write the message followed by a newline.
    // Use a lock on stdout to ensure atomicity.
    use std::io::Write;
    let stdout = std::io::stdout();
    let mut handle = stdout.lock();
    // Ignore write errors (broken pipe, etc.) — the MCP client has disconnected.
    let _ = writeln!(handle, "{serialized}");
    let _ = handle.flush();
}

// ---------------------------------------------------------------------------
// MCP method handlers
// ---------------------------------------------------------------------------

/// Handles the `initialize` request.
///
/// Returns server info and capabilities as specified by the MCP protocol.
fn handle_initialize(id: &Value) -> Value {
    jsonrpc_result(
        id,
        json!({
            "protocolVersion": PROTOCOL_VERSION,
            "serverInfo": {
                "name": SERVER_NAME,
                "version": SERVER_VERSION,
            },
            "capabilities": {
                "tools": {},
                "prompts": {},
            },
        }),
    )
}

/// Handles `tools/list` requests.
///
/// Returns the list of available tools with their input schemas.
fn handle_tools_list(id: &Value) -> Value {
    jsonrpc_result(
        id,
        json!({
            "tools": [
                exec_script_tool(),
                trace_info_tool(),
                list_source_files_tool(),
                read_source_file_tool(),
            ]
        }),
    )
}

/// Handles `tools/call` requests.
///
/// Dispatches to the appropriate tool handler based on the tool name.
async fn handle_tools_call(
    id: &Value,
    params: Option<&Value>,
    config: &McpServerConfig,
) -> Value {
    let tool_name = params
        .and_then(|p| p.get("name"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let arguments = params.and_then(|p| p.get("arguments"));

    match tool_name {
        "exec_script" => handle_exec_script(id, arguments, config).await,
        "trace_info" => handle_trace_info(id, arguments, config).await,
        "list_source_files" => handle_list_source_files(id, arguments, config).await,
        "read_source_file" => handle_read_source_file(id, arguments, config).await,
        _ => jsonrpc_error(
            id,
            -32602,
            &format!("Unknown tool: {tool_name}"),
        ),
    }
}

/// Handles `prompts/list` requests.
///
/// Returns the list of available prompts.
fn handle_prompts_list(id: &Value) -> Value {
    jsonrpc_result(
        id,
        json!({
            "prompts": [
                {
                    "name": "trace_query_api",
                    "description": "Returns the CodeTracer Trace Query Python API reference documentation, including data types, Trace class methods, and usage examples.",
                }
            ]
        }),
    )
}

/// Handles `prompts/get` requests.
///
/// Returns the content for the requested prompt.
fn handle_prompts_get(id: &Value, params: Option<&Value>) -> Value {
    let prompt_name = params
        .and_then(|p| p.get("name"))
        .and_then(Value::as_str)
        .unwrap_or("");

    match prompt_name {
        "trace_query_api" => jsonrpc_result(
            id,
            json!({
                "description": "CodeTracer Trace Query API Reference",
                "messages": [
                    {
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": trace_query_api_reference(),
                        }
                    }
                ]
            }),
        ),
        _ => jsonrpc_error(
            id,
            -32602,
            &format!("Unknown prompt: {prompt_name}"),
        ),
    }
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

/// Connects to the daemon, auto-starting it if needed.
///
/// This mirrors the `ensure_daemon_connected` function in main.rs but
/// is self-contained for the MCP server module.
async fn connect_to_daemon(config: &McpServerConfig) -> Result<UnixStream, String> {
    // Check for CODETRACER_DAEMON_SOCK override (used in tests).
    if let Ok(sock_path) = std::env::var("CODETRACER_DAEMON_SOCK") {
        let path = PathBuf::from(&sock_path);
        return UnixStream::connect(&path)
            .await
            .map_err(|e| format!("cannot connect to daemon at {sock_path}: {e}"));
    }

    let socket_path = &config.daemon_socket_path;

    // Try to connect to an already-running daemon.
    if socket_path.exists()
        && let Ok(stream) = UnixStream::connect(socket_path).await
    {
        return Ok(stream);
    }
    // Socket may exist but connection failed — stale.  Remove it if present.
    if socket_path.exists() {
        let _ = tokio::fs::remove_file(socket_path).await;
    }

    // Clean up stale PID file if the process is dead.
    let pid_path = &config.daemon_pid_path;
    if pid_path.exists() {
        let contents = tokio::fs::read_to_string(pid_path)
            .await
            .unwrap_or_default();
        if let Ok(old_pid) = contents.trim().parse::<u32>() {
            // SAFETY: signal 0 does not kill anything; it only checks existence.
            let alive = unsafe { libc::kill(old_pid as libc::pid_t, 0) == 0 };
            if !alive {
                let _ = tokio::fs::remove_file(pid_path).await;
            }
        }
    }

    // Ensure the parent directory exists.
    if let Some(parent) = socket_path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("cannot create daemon socket directory: {e}"))?;
    }

    // Spawn the daemon process.
    let exe = std::env::current_exe()
        .map_err(|e| format!("cannot determine current executable: {e}"))?;
    eprintln!("mcp: auto-starting daemon: {} daemon start", exe.display());

    std::process::Command::new(&exe)
        .arg("daemon")
        .arg("start")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("failed to spawn daemon: {e}"))?;

    // Poll for the socket with exponential backoff.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut delay = Duration::from_millis(50);

    loop {
        tokio::time::sleep(delay).await;

        if socket_path.exists()
            && let Ok(stream) = UnixStream::connect(socket_path).await
        {
            return Ok(stream);
        }

        if tokio::time::Instant::now() > deadline {
            return Err("timeout waiting for daemon to start".to_string());
        }

        delay = (delay * 2).min(Duration::from_millis(500));
    }
}

/// Handles the `exec_script` tool.
///
/// Sends a `ct/exec-script` request to the daemon and returns the
/// script's stdout as the tool result.  Errors and timeouts are
/// reported via `isError: true` in the MCP response.
async fn handle_exec_script(
    id: &Value,
    arguments: Option<&Value>,
    config: &McpServerConfig,
) -> Value {
    let trace_path = match arguments.and_then(|a| a.get("trace_path")).and_then(Value::as_str) {
        Some(p) => p,
        None => {
            return jsonrpc_result(
                id,
                tool_result_error("Missing required argument: trace_path"),
            );
        }
    };

    let script = match arguments.and_then(|a| a.get("script")).and_then(Value::as_str) {
        Some(s) => s,
        None => {
            return jsonrpc_result(
                id,
                tool_result_error("Missing required argument: script"),
            );
        }
    };

    let timeout_seconds = arguments
        .and_then(|a| a.get("timeout_seconds"))
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_SCRIPT_TIMEOUT);

    let mut stream = match connect_to_daemon(config).await {
        Ok(s) => s,
        Err(e) => {
            return jsonrpc_result(
                id,
                tool_result_error(&format!("Cannot connect to daemon: {e}")),
            );
        }
    };

    // Send ct/exec-script to the daemon.
    // Use a generous deadline: script timeout + overhead for trace opening.
    let resp = match dap_request(
        &mut stream,
        "ct/exec-script",
        1,
        json!({
            "tracePath": trace_path,
            "script": script,
            "timeout": timeout_seconds,
        }),
        timeout_seconds + 30,
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            return jsonrpc_result(
                id,
                tool_result_error(&format!("Daemon request failed: {e}")),
            );
        }
    };

    // Check the daemon response for success/failure.
    if resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return jsonrpc_result(
            id,
            tool_result_error(&format!("Script execution failed: {message}")),
        );
    }

    let body = resp.get("body").cloned().unwrap_or(json!({}));
    let stdout = body.get("stdout").and_then(Value::as_str).unwrap_or("");
    let stderr = body.get("stderr").and_then(Value::as_str).unwrap_or("");
    let exit_code = body.get("exitCode").and_then(Value::as_i64).unwrap_or(0);
    let timed_out = body
        .get("timedOut")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if timed_out {
        return jsonrpc_result(
            id,
            tool_result_error(&format!(
                "Script execution timed out after {timeout_seconds} seconds"
            )),
        );
    }

    if exit_code != 0 {
        // Script error — include both stderr and stdout so the agent
        // can see the full error context.
        let mut error_text = String::new();
        if !stderr.is_empty() {
            error_text.push_str(&format!("Error: {stderr}"));
        }
        if !stdout.is_empty() {
            if !error_text.is_empty() {
                error_text.push('\n');
            }
            error_text.push_str(&format!("Output: {stdout}"));
        }
        if error_text.is_empty() {
            error_text = format!("Script exited with code {exit_code}");
        }
        return jsonrpc_result(id, tool_result_error(&error_text));
    }

    // Success — return stdout as the tool result.
    jsonrpc_result(id, tool_result_text(stdout))
}

/// Handles the `trace_info` tool.
///
/// Opens the trace (if not already open) and returns metadata: language,
/// event count, source files, program, and working directory.
async fn handle_trace_info(
    id: &Value,
    arguments: Option<&Value>,
    config: &McpServerConfig,
) -> Value {
    let trace_path = match arguments.and_then(|a| a.get("trace_path")).and_then(Value::as_str) {
        Some(p) => p,
        None => {
            return jsonrpc_result(
                id,
                tool_result_error("Missing required argument: trace_path"),
            );
        }
    };

    let mut stream = match connect_to_daemon(config).await {
        Ok(s) => s,
        Err(e) => {
            return jsonrpc_result(
                id,
                tool_result_error(&format!("Cannot connect to daemon: {e}")),
            );
        }
    };

    // Open the trace first (idempotent if already open).
    let open_resp = match dap_request(
        &mut stream,
        "ct/open-trace",
        1,
        json!({"tracePath": trace_path}),
        30,
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            return jsonrpc_result(
                id,
                tool_result_error(&format!("Failed to open trace: {e}")),
            );
        }
    };

    if open_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = open_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return jsonrpc_result(
            id,
            tool_result_error(&format!("Failed to open trace: {message}")),
        );
    }

    // Query trace info.
    let info_resp = match dap_request(
        &mut stream,
        "ct/trace-info",
        2,
        json!({"tracePath": trace_path}),
        10,
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            return jsonrpc_result(
                id,
                tool_result_error(&format!("Failed to get trace info: {e}")),
            );
        }
    };

    if info_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = info_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return jsonrpc_result(
            id,
            tool_result_error(&format!("Failed to get trace info: {message}")),
        );
    }

    let body = info_resp.get("body").cloned().unwrap_or(json!({}));

    // Format the trace info as human-readable text for the LLM.
    let mut text = String::new();
    text.push_str("Trace Information\n");
    if let Some(path) = body.get("tracePath").and_then(Value::as_str) {
        text.push_str(&format!("  Path: {path}\n"));
    }
    if let Some(lang) = body.get("language").and_then(Value::as_str) {
        text.push_str(&format!("  Language: {lang}\n"));
    }
    if let Some(events) = body.get("totalEvents").and_then(Value::as_u64) {
        text.push_str(&format!("  Total events: {events}\n"));
    }
    if let Some(program) = body.get("program").and_then(Value::as_str) {
        text.push_str(&format!("  Program: {program}\n"));
    }
    if let Some(workdir) = body.get("workdir").and_then(Value::as_str) {
        text.push_str(&format!("  Working dir: {workdir}\n"));
    }
    if let Some(files) = body.get("sourceFiles").and_then(Value::as_array) {
        text.push_str(&format!("  Source files: ({} files)\n", files.len()));
        for file in files {
            if let Some(path) = file.as_str() {
                text.push_str(&format!("    - {path}\n"));
            }
        }
    }

    jsonrpc_result(id, tool_result_text(&text))
}

/// Handles the `list_source_files` tool.
///
/// Opens the trace and returns the list of source files from the
/// trace info metadata.
async fn handle_list_source_files(
    id: &Value,
    arguments: Option<&Value>,
    config: &McpServerConfig,
) -> Value {
    let trace_path = match arguments.and_then(|a| a.get("trace_path")).and_then(Value::as_str) {
        Some(p) => p,
        None => {
            return jsonrpc_result(
                id,
                tool_result_error("Missing required argument: trace_path"),
            );
        }
    };

    let mut stream = match connect_to_daemon(config).await {
        Ok(s) => s,
        Err(e) => {
            return jsonrpc_result(
                id,
                tool_result_error(&format!("Cannot connect to daemon: {e}")),
            );
        }
    };

    // Open the trace first.
    let open_resp = match dap_request(
        &mut stream,
        "ct/open-trace",
        1,
        json!({"tracePath": trace_path}),
        30,
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            return jsonrpc_result(
                id,
                tool_result_error(&format!("Failed to open trace: {e}")),
            );
        }
    };

    if open_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = open_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return jsonrpc_result(
            id,
            tool_result_error(&format!("Failed to open trace: {message}")),
        );
    }

    // Get trace info to retrieve the source file list.
    let info_resp = match dap_request(
        &mut stream,
        "ct/trace-info",
        2,
        json!({"tracePath": trace_path}),
        10,
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            return jsonrpc_result(
                id,
                tool_result_error(&format!("Failed to get trace info: {e}")),
            );
        }
    };

    if info_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = info_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return jsonrpc_result(
            id,
            tool_result_error(&format!("Failed to get trace info: {message}")),
        );
    }

    let body = info_resp.get("body").cloned().unwrap_or(json!({}));
    let files = body
        .get("sourceFiles")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    // Format as a newline-separated list.
    let mut text = String::new();
    for file in &files {
        if let Some(path) = file.as_str() {
            text.push_str(path);
            text.push('\n');
        }
    }

    jsonrpc_result(id, tool_result_text(&text))
}

/// Handles the `read_source_file` tool.
///
/// Opens the trace and sends `ct/py-read-source` to the daemon to
/// retrieve the content of a source file.
async fn handle_read_source_file(
    id: &Value,
    arguments: Option<&Value>,
    config: &McpServerConfig,
) -> Value {
    let trace_path = match arguments.and_then(|a| a.get("trace_path")).and_then(Value::as_str) {
        Some(p) => p,
        None => {
            return jsonrpc_result(
                id,
                tool_result_error("Missing required argument: trace_path"),
            );
        }
    };

    let file_path = match arguments.and_then(|a| a.get("file_path")).and_then(Value::as_str) {
        Some(p) => p,
        None => {
            return jsonrpc_result(
                id,
                tool_result_error("Missing required argument: file_path"),
            );
        }
    };

    let mut stream = match connect_to_daemon(config).await {
        Ok(s) => s,
        Err(e) => {
            return jsonrpc_result(
                id,
                tool_result_error(&format!("Cannot connect to daemon: {e}")),
            );
        }
    };

    // Open the trace first.
    let open_resp = match dap_request(
        &mut stream,
        "ct/open-trace",
        1,
        json!({"tracePath": trace_path}),
        30,
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            return jsonrpc_result(
                id,
                tool_result_error(&format!("Failed to open trace: {e}")),
            );
        }
    };

    if open_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = open_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return jsonrpc_result(
            id,
            tool_result_error(&format!("Failed to open trace: {message}")),
        );
    }

    // Send ct/py-read-source to the daemon.
    let read_resp = match dap_request(
        &mut stream,
        "ct/py-read-source",
        2,
        json!({
            "tracePath": trace_path,
            "path": file_path,
        }),
        10,
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            return jsonrpc_result(
                id,
                tool_result_error(&format!("Failed to read source file: {e}")),
            );
        }
    };

    if read_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = read_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return jsonrpc_result(
            id,
            tool_result_error(&format!("Failed to read source file: {message}")),
        );
    }

    let body = read_resp.get("body").cloned().unwrap_or(json!({}));
    let content = body
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or("");

    jsonrpc_result(id, tool_result_text(content))
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_jsonrpc_result_structure() {
        let result = jsonrpc_result(&json!(1), json!({"key": "value"}));
        assert_eq!(result["jsonrpc"], "2.0");
        assert_eq!(result["id"], 1);
        assert_eq!(result["result"]["key"], "value");
    }

    #[test]
    fn test_jsonrpc_error_structure() {
        let error = jsonrpc_error(&json!(1), -32601, "Method not found");
        assert_eq!(error["jsonrpc"], "2.0");
        assert_eq!(error["id"], 1);
        assert_eq!(error["error"]["code"], -32601);
        assert_eq!(error["error"]["message"], "Method not found");
    }

    #[test]
    fn test_tool_result_text() {
        let result = tool_result_text("hello");
        assert_eq!(result["content"][0]["type"], "text");
        assert_eq!(result["content"][0]["text"], "hello");
        assert!(result.get("isError").is_none());
    }

    #[test]
    fn test_tool_result_error() {
        let result = tool_result_error("something went wrong");
        assert_eq!(result["content"][0]["type"], "text");
        assert_eq!(result["content"][0]["text"], "something went wrong");
        assert_eq!(result["isError"], true);
    }

    #[test]
    fn test_handle_initialize() {
        let resp = handle_initialize(&json!(1));
        assert_eq!(resp["id"], 1);
        let result = &resp["result"];
        assert_eq!(result["protocolVersion"], PROTOCOL_VERSION);
        assert_eq!(result["serverInfo"]["name"], SERVER_NAME);
        assert_eq!(result["serverInfo"]["version"], SERVER_VERSION);
        assert!(result["capabilities"]["tools"].is_object());
        assert!(result["capabilities"]["prompts"].is_object());
    }

    #[test]
    fn test_handle_tools_list() {
        let resp = handle_tools_list(&json!(2));
        let tools = resp["result"]["tools"].as_array().expect("tools array");
        assert_eq!(tools.len(), 4);

        let names: Vec<&str> = tools
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert!(names.contains(&"exec_script"));
        assert!(names.contains(&"trace_info"));
        assert!(names.contains(&"list_source_files"));
        assert!(names.contains(&"read_source_file"));

        // Verify each tool has an inputSchema.
        for tool in tools {
            assert!(tool.get("inputSchema").is_some(), "tool missing inputSchema");
        }
    }

    #[test]
    fn test_handle_prompts_list() {
        let resp = handle_prompts_list(&json!(3));
        let prompts = resp["result"]["prompts"].as_array().expect("prompts array");
        assert_eq!(prompts.len(), 1);
        assert_eq!(prompts[0]["name"], "trace_query_api");
    }

    #[test]
    fn test_handle_prompts_get_known() {
        let resp = handle_prompts_get(
            &json!(4),
            Some(&json!({"name": "trace_query_api"})),
        );
        let messages = resp["result"]["messages"]
            .as_array()
            .expect("messages array");
        assert_eq!(messages.len(), 1);
        let text = messages[0]["content"]["text"].as_str().expect("text");
        assert!(text.contains("Trace Query API"));
        assert!(text.contains("trace.step_over"));
        assert!(text.contains("Variable"));
    }

    #[test]
    fn test_handle_prompts_get_unknown() {
        let resp = handle_prompts_get(&json!(5), Some(&json!({"name": "nonexistent"})));
        assert!(resp.get("error").is_some());
    }

    #[test]
    fn test_api_reference_is_under_10kb() {
        let text = trace_query_api_reference();
        assert!(
            text.len() < 10 * 1024,
            "API reference is {} bytes, should be under 10KB",
            text.len()
        );
    }

    #[test]
    fn test_api_reference_is_under_300_lines() {
        let text = trace_query_api_reference();
        let lines = text.lines().count();
        assert!(
            lines < 300,
            "API reference is {lines} lines, should be under 300",
        );
    }
}
