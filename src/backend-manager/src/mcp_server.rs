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
//! - Resources are exposed via `resources/list` and fetched via `resources/read`
//! - Resource templates are listed via `resources/templates/list`
//!
//! # Architecture
//!
//! The MCP server is a CLIENT of the CodeTracer daemon.  It connects to the
//! daemon's Unix socket (auto-starting the daemon if needed) and sends
//! DAP-framed messages to execute tool operations.  This is the same
//! communication pattern used by the CLI (`ct trace query`, `ct trace info`).
//!
//! # Resource Tracking
//!
//! The server tracks which traces have been loaded (via `exec_script` or
//! `trace_info` tool calls).  Once a trace is loaded, its metadata and
//! source files become available as MCP resources through `resources/list`
//! and `resources/read`.
//!
//! The trace URI format is: `trace:///<trace_path>/<resource_type>[/<sub_path>]`
//!
//! Examples:
//! - `trace:///home/user/traces/my-program/info` - trace metadata (JSON)
//! - `trace:///home/user/traces/my-program/source/src/main.nim` - source file

use std::collections::HashMap;
use std::io::BufRead;
use std::path::PathBuf;
use std::time::{Duration, Instant};

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
///
/// 120 s is generous enough for large Python DB traces (which can be
/// 50–100 MB and require loading the full event table before answering
/// calltrace / terminal_output queries).
const DEFAULT_SCRIPT_TIMEOUT: u64 = 120;

/// URI scheme prefix for trace resources.
///
/// This is `trace://` (scheme + empty authority).  When an absolute trace
/// path like `/tmp/trace-dir` is appended, the result is
/// `trace:///tmp/trace-dir/info` (three slashes: two from the prefix, one
/// from the path's leading `/`).
const TRACE_URI_PREFIX: &str = "trace://";

// ---------------------------------------------------------------------------
// Tool schemas
// ---------------------------------------------------------------------------

/// Returns the JSON schema for the `exec_script` tool.
fn exec_script_tool() -> Value {
    json!({
        "name": "exec_script",
        "description": "Execute a Python script against a CodeTracer trace file. The `trace` variable is pre-bound to the opened trace.\n\nAvailable trace methods:\n- Navigation: trace.step_over(), step_in(), step_out(), step_back(), continue_forward(), continue_reverse(), goto_ticks(n)\n- Breakpoints: trace.add_breakpoint(path, line) -> id, remove_breakpoint(id)\n- Watchpoints: trace.add_watchpoint(expr) -> id, remove_watchpoint(id)\n- Tracepoints: trace.add_tracepoint(path, line, expr) -> id, remove_tracepoint(id), run_tracepoints() -> results\n- Inspection: trace.locals(), evaluate(expr), stack_trace(), location, ticks\n- Value Trace: trace.value_trace(path, line, mode='call') -> ValueTrace with .steps and .loops\n- Data: trace.source_files, calltrace(), events(), terminal_output()\n- Source: trace.read_source(path)\n\nAll navigation methods raise StopIteration at trace boundaries. Print results to stdout.\n\nUse the optional 'session_id' parameter to preserve execution state (breakpoints, position) across multiple calls — this enables incremental step-by-step debugging.\n\nUse the 'trace_query_api' prompt for the full API reference with data types and examples.",
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
                    "description": "Maximum execution time in seconds (default: 120)",
                    "default": 120
                },
                "session_id": {
                    "type": "string",
                    "description": "Optional session identifier.  When provided, execution state (breakpoints, current position) is preserved between calls with the same session_id.  Sessions expire after 5 minutes of inactivity; if you get a 'no session loaded' error, the session has expired and you should start a new one.  Omit for one-shot scripts.  Use a descriptive name like 'debug-1'."
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
opened trace in every script.  All navigation methods return a `Location`
and raise `StopIteration` at trace boundaries.

## Debugging Philosophy

Once you capture a bug in a recording, you can be certain that you will
find the root cause using these powerful tools:

**Watchpoints — Track down the origin of any value.**  When you encounter
an unexpected value, set a watchpoint on the variable and continue backward.
CodeTracer will stop at the exact moment and code line where that memory
location was last written to.  Repeat this "where did this value come from?"
question — it usually takes just a few jumps to reach the root cause.

**Tracepoints — Printf debugging without recompilation.**  A tracepoint
evaluates a custom expression every time execution passes through a line,
across the entire recorded execution.  You get the same insight as adding
print statements but without recompiling, rerunning, or cleaning up
debugging code.  The expression language supports log(), variables, field
access, arithmetic, and conditionals.

## Exceptions

All exceptions inherit from `TraceError`:
- `TraceError` - Base exception for all trace operations
- `TraceNotFoundError` - Trace does not exist or cannot be opened
- `NavigationError` - Navigation operation failed (distinct from StopIteration at boundaries)
- `ExpressionError` - Expression evaluation failed (raised by evaluate())
- `TimeoutError` - Backend operation timed out

Navigation methods raise `NavigationError` on general failure and `StopIteration`
specifically at trace boundaries (start/end of trace).

## Data Types

All data types support both attribute access (`var.name`) and dict-style
access (`var['name']`).  Common aliases: `call['function']` for
`call.function_name`, `var['type']` for `var.type_name`.  Use
`obj.get('key', default)` for safe access with a fallback.

### Location
- `path: str` - Source file path
- `line: int` - Line number (1-based)
- `column: int` - Column number (0 = unknown)

### Variable
- `name: str` - Variable name
- `value: str` - String representation of the value
- `type_name: str | None` - Type name (also accessible as `var['type']`)
- `children: list[Variable]` - Nested fields/elements

### Frame
- `function_name: str` - Function name (also accessible as `frame['function']`)
- `location: Location` - Source location
- `variables: list[Variable]` - Variables in this frame's scope (may be empty)

### FlowStep
- `location: Location` - Source location of this step
- `ticks: int` - Execution timestamp
- `loop_id: int` - Loop identifier (0 = not in loop)
- `iteration: int` - Loop iteration index
- `before_values: dict[str, str]` - Variable values before step
- `after_values: dict[str, str]` - Variable values after step

### ValueTrace
- `steps: list[FlowStep]` - Execution steps
- `loops: list[Loop]` - Loop information

### Loop
- `id: int` - Loop identifier
- `location: Location` - Source location of the loop header
- `start_line: int` - First line of the loop
- `end_line: int` - Last line of the loop
- `iteration_count: int` - Total iterations

### Call
- `function_name: str` - Function name (also accessible as `call['function']`)
- `location: Location` - Call site location
- `arguments: list[Variable]` - Captured argument values
- `return_value: Variable | None` - Return value (if available)
- `id: int` - Call identifier
- `children_count: int` - Number of child calls
- `depth: int` - Call tree depth (0 = top-level)

### Event
- `kind: str` - Event type ("stdout", "stderr", etc.)
- `message: str` - Human-readable description
- `content: str` - Raw event content
- `ticks: int` - Execution timestamp
- `location: Location | None` - Source location
- `id: int` - Unique event identifier
- `data: dict | None` - Arbitrary event-specific payload

### Process
- `id: int` - Process identifier
- `name: str` - Process name
- `command: str` - Command line

### TracepointResult
- `tracepointId: int` - Which tracepoint produced this hit
- `path: str` - Source file path
- `line: int` - Line number
- `ticks: int` - Execution timestamp
- `iteration: int` - Visit index (0 for first hit, 1 for second, etc.)
- `values: list[dict]` - Evaluated expression results: [{"name": str, "value": str}]

## Trace Class

### Properties
- `trace.location -> Location` - Current execution position
- `trace.ticks -> int` - Current execution timestamp (rr ticks)
- `trace.source_files -> list[str]` - All source file paths
- `trace.total_events -> int` - Total number of trace events
- `trace.language -> str` - Programming language of the traced program

### Navigation (all return Location; raise StopIteration at boundaries, NavigationError on failure)
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
- `trace.locals(depth=3, count_budget=3000) -> list[Variable]` - Local variables
- `trace.evaluate(expr: str) -> str` - Evaluate an expression, returns string result.
  Raises `ExpressionError` if evaluation fails.
  - **Note**: On DB traces (Python), only matches local variable names. Use `trace.locals()` for available variables.
- `trace.stack_trace() -> list[Frame]` - Current call stack
- `trace.current_frame() -> Frame` - Topmost call frame

### Breakpoints
- `trace.add_breakpoint(path: str, line: int) -> int` - Set a breakpoint, returns ID
- `trace.remove_breakpoint(bp_id: int)` - Remove a breakpoint by ID
- `trace.add_watchpoint(expression: str) -> int` - Watch for value changes, returns ID
- `trace.remove_watchpoint(wp_id: int)` - Remove a watchpoint by ID

### Tracepoints
- `trace.add_tracepoint(path: str, line: int, expression: str) -> int`
  Add a tracepoint. Expression uses `log(expr, ...)` to capture values.
  Returns a tracepoint ID.
- `trace.remove_tracepoint(tp_id: int)` - Remove a tracepoint by ID
- `trace.run_tracepoints(stop_after: int = -1) -> list[TracepointResult]`
  Execute all tracepoints across the full trace.  Returns all hits.

### Value Trace (Omniscience)
- `trace.value_trace(path: str, line: int, mode="call") -> ValueTrace`
  - Get value-trace (omniscience) data for a line: all variable values across execution.
  - `mode="call"`: full function scope.  `mode="line"`: single line.


### Call Trace
- `trace.calltrace(start=0, count=50, depth=10) -> list[Call]`
- `trace.search_calltrace(query: str, limit=100) -> list[Call]`
- `trace.calls(function_name: str | None = None) -> list[Call]`

### Events
- `trace.events(start=0, count=100, type_filter=None, search=None) -> list[Event]`
- `trace.terminal_output(start_line=0, end_line=-1) -> str`

### Multi-process
- `trace.processes() -> list[Process]` - List all processes in the trace.
- `trace.select_process(process_id: int)` - Switch to a different process.

### Source Files
- `trace.read_source(path: str) -> str` - Read a source file's content.

## Sessions

Use the `session_id` parameter in `exec_script` to maintain execution state
(breakpoints, current position) across multiple calls.  This enables
incremental debugging — set a breakpoint in one call, step through code
in the next, inspect variables in a third.

Without `session_id`, each `exec_script` call starts a fresh trace session
that is discarded when the script ends.

**Important**: Sessions expire after 5 minutes of inactivity.  If you receive
a "no session loaded" error, the session has timed out — call `open_trace()`
again or start a new `exec_script` call to create a fresh session.

**Tip**: Prefer short, focused scripts with sessions over long monolithic
scripts.  If one step fails, you can adjust without losing prior state.

## Example 1: Print location and local variables

```python
print(f"At {trace.location.path}:{trace.location.line}")
for var in trace.locals():
    print(f"  {var.name} = {var.value}")
```

## Example 2: Step through code and collect variable values

```python
values = []
for _ in range(10):
    try:
        trace.step_over()
    except StopIteration:
        break
    result = trace.evaluate("x")
    values.append(result)
print("x values:", values)
```

## Example 3: Use breakpoints to find a specific state

```python
# Use trace.location.path to reference the current source file
# (works regardless of language).
path = trace.location.path
bp = trace.add_breakpoint(path, trace.location.line + 5)
try:
    trace.continue_forward()
    print(f"Hit breakpoint at {trace.location}")
    for var in trace.locals():
        print(f"  {var.name} = {var.value}")
except StopIteration:
    print(f"Reached trace boundary before breakpoint")
trace.remove_breakpoint(bp)
```

## Example 4: Analyze a loop with value trace (omniscience)

```python
# Use trace.location.path to dynamically pick the file
path = trace.location.path
line = trace.location.line
vt = trace.value_trace(path, line, mode="call")
for loop in vt.loops:
    print(f"Loop at lines {loop.start_line}-{loop.end_line}: {loop.iteration_count} iterations")
for step in vt.steps:
    if step.loop_id > 0:
        print(f"  line {step.location.line} iter {step.iteration}: {step.after_values}")
```

## Example 5: List source files and inspect the call stack

```python
files = trace.source_files
print(f"Trace has {len(files)} source file(s)")
for f in files[:5]:
    print(f"  {f}")
stack = trace.stack_trace()
print(f"Call stack depth: {len(stack)}")
for frame in stack:
    print(f"  {frame.function_name} at {frame.location.path}:{frame.location.line}")
```

## Example 6: Incremental debugging with sessions

Use `session_id` to preserve state across multiple `exec_script` calls:

**Call 1** (session_id="dbg"):
```python
# Set a breakpoint and run to it
bp = trace.add_breakpoint(trace.source_files[0], 42)
trace.continue_forward()
print(f"Stopped at {trace.location.path}:{trace.location.line}")
for v in trace.locals():
    print(f"  {v.name} = {v.value}")
```

**Call 2** (same session_id="dbg"):
```python
# Breakpoint and position are preserved — step forward
trace.step_over()
print(f"Now at {trace.location.path}:{trace.location.line}")
for v in trace.locals():
    print(f"  {v.name} = {v.value}")
```

## Example 7: Explore the call trace

```python
# List all function calls recorded in the trace
for call in trace.calltrace():
    indent = "  " * call.depth
    print(f"{indent}{call.function_name} at {call.location.path}:{call.location.line}")

# Search for specific function calls
for call in trace.search_calltrace("process"):
    print(f"{call.function_name}: {call.children_count} child calls")
```

## Example 8: Read program output

```python
# Get everything the program printed to stdout/stderr
output = trace.terminal_output()
if output.strip():
    print(output)
else:
    print("(no terminal output captured)")
```

## Example 9: Tracepoints — printf debugging without recompilation

```python
# Add a tracepoint to see loop variable values at a specific line
tp = trace.add_tracepoint(trace.location.path, 42, "log(i, total)")
results = trace.run_tracepoints()
for r in results:
    vals = ", ".join(f"{v['name']}={v['value']}" for v in r["values"])
    print(f"  hit #{r['iteration']} ticks={r['ticks']}: {vals}")
trace.remove_tracepoint(tp)
```

## Tips

- All data types support both attribute and dict-style access:
  `var.name` and `var['name']` are equivalent.
- Common aliases: `call['function']` for `call.function_name`,
  `var['type']` for `var.type_name`.
- Use `var.get('field', default)` for safe access with a fallback.
- `evaluate()` returns a **string**, not a typed value — use `int(trace.evaluate("x"))` for arithmetic.
- FlowStep has no `.line` — use `step.location.line` (location is a nested Location object).
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
            eprintln!("mcp: skipping interleaved DAP event while waiting for {command} response");
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
///
/// Note: Production code currently uses `tool_result_text_with_timing` for
/// all responses.  This function is retained for completeness and tested
/// in unit tests.
#[allow(dead_code)]
fn tool_result_text(text: &str) -> Value {
    json!({
        "content": [{"type": "text", "text": text}],
    })
}

/// Builds an MCP tool result with text content and timing metadata.
///
/// The `_meta.duration_ms` field reports how long the tool execution
/// took in milliseconds.  This helps agents gauge script performance
/// and detect slow queries.
fn tool_result_text_with_timing(text: &str, duration_ms: u128) -> Value {
    json!({
        "content": [{"type": "text", "text": text}],
        "_meta": {"duration_ms": duration_ms},
    })
}

/// Builds an MCP tool result indicating an error (isError: true).
fn tool_result_error(text: &str) -> Value {
    json!({
        "content": [{"type": "text", "text": text}],
        "isError": true,
    })
}

/// Builds an MCP tool result indicating an error with timing metadata.
fn tool_result_error_with_timing(text: &str, duration_ms: u128) -> Value {
    json!({
        "content": [{"type": "text", "text": text}],
        "isError": true,
        "_meta": {"duration_ms": duration_ms},
    })
}

// ---------------------------------------------------------------------------
// Loaded trace metadata (for MCP resource tracking)
// ---------------------------------------------------------------------------

/// Metadata for a trace that has been loaded through a tool call.
///
/// This is cached in-process so that `resources/list` can enumerate
/// available resources without re-querying the daemon.
#[derive(Debug, Clone)]
struct LoadedTrace {
    /// Detected programming language (e.g. "nim", "rust").
    language: String,
    /// Total number of execution events.
    total_events: u64,
    /// Source files within the trace.
    source_files: Vec<String>,
    /// The program that was traced.
    program: String,
    /// Working directory at recording time.
    workdir: String,
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
/// The server maintains an in-process cache of loaded traces so that
/// `resources/list` and `resources/read` can serve resource data without
/// requiring separate daemon queries.
///
/// The `config` parameter provides the daemon socket and PID file paths.
pub async fn run_mcp_server(config: McpServerConfig) -> Result<(), Box<dyn std::error::Error>> {
    let stdin = std::io::stdin();
    let reader = stdin.lock();

    // In-process cache of traces loaded during this session.
    // Populated by handle_exec_script and handle_trace_info on success.
    let mut loaded_traces: HashMap<String, LoadedTrace> = HashMap::new();

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
        let method = msg.get("method").and_then(Value::as_str).unwrap_or("");

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
                let response = handle_tools_call(&id, params, &config, &mut loaded_traces).await;
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
            "resources/list" => {
                let response = handle_resources_list(&id, &loaded_traces);
                write_jsonrpc_message(&response);
            }
            "resources/read" => {
                let params = msg.get("params");
                let response = handle_resources_read(&id, params, &config, &loaded_traces).await;
                write_jsonrpc_message(&response);
            }
            "resources/templates/list" => {
                let response = handle_resource_templates_list(&id);
                write_jsonrpc_message(&response);
            }
            _ => {
                if !is_notification {
                    let response =
                        jsonrpc_error(&id, -32601, &format!("Method not found: {method}"));
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
/// Advertises `tools`, `prompts`, and `resources` capabilities.
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
                "resources": {},
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
/// On successful trace operations, updates `loaded_traces` so that
/// subsequent `resources/list` calls reflect the newly loaded trace.
async fn handle_tools_call(
    id: &Value,
    params: Option<&Value>,
    config: &McpServerConfig,
    loaded_traces: &mut HashMap<String, LoadedTrace>,
) -> Value {
    let tool_name = params
        .and_then(|p| p.get("name"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let arguments = params.and_then(|p| p.get("arguments"));

    match tool_name {
        "exec_script" => handle_exec_script(id, arguments, config, loaded_traces).await,
        "trace_info" => handle_trace_info(id, arguments, config, loaded_traces).await,
        "list_source_files" => handle_list_source_files(id, arguments, config).await,
        "read_source_file" => handle_read_source_file(id, arguments, config).await,
        _ => jsonrpc_error(id, -32602, &format!("Unknown tool: {tool_name}")),
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
        _ => jsonrpc_error(id, -32602, &format!("Unknown prompt: {prompt_name}")),
    }
}

// ---------------------------------------------------------------------------
// Resource handlers
// ---------------------------------------------------------------------------

/// Handles `resources/list` requests.
///
/// Returns resources for all traces that have been loaded during this
/// session.  Each loaded trace produces:
/// - A `trace:///<path>/info` resource (application/json) for metadata
/// - A `trace:///<path>/source/<file>` resource (text/plain) for each
///   source file in the trace
fn handle_resources_list(id: &Value, loaded_traces: &HashMap<String, LoadedTrace>) -> Value {
    let mut resources = Vec::new();

    // Sort keys for deterministic output (important for tests).
    let mut trace_paths: Vec<&String> = loaded_traces.keys().collect();
    trace_paths.sort();

    for trace_path in trace_paths {
        let trace = &loaded_traces[trace_path];

        // Trace info resource.
        resources.push(json!({
            "uri": format!("{TRACE_URI_PREFIX}{trace_path}/info"),
            "name": "Trace Info",
            "description": format!("Metadata about the trace at {trace_path}"),
            "mimeType": "application/json",
        }));

        // Source file resources.
        for file in &trace.source_files {
            resources.push(json!({
                "uri": format!("{TRACE_URI_PREFIX}{trace_path}/source/{file}"),
                "name": file,
                "description": format!("Source file from trace at {trace_path}"),
                "mimeType": "text/plain",
            }));
        }
    }

    jsonrpc_result(id, json!({"resources": resources}))
}

/// Handles `resources/read` requests.
///
/// Parses the `trace:///` URI to determine the trace path and resource
/// type, then returns the appropriate content:
/// - `/info` suffix: returns JSON metadata about the trace
/// - `/source/<file>` suffix: returns the source file content from the daemon
fn handle_resources_read<'a>(
    id: &'a Value,
    params: Option<&'a Value>,
    config: &'a McpServerConfig,
    loaded_traces: &'a HashMap<String, LoadedTrace>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Value> + 'a>> {
    Box::pin(async move {
        let uri = match params.and_then(|p| p.get("uri")).and_then(Value::as_str) {
            Some(u) => u,
            None => {
                return jsonrpc_error(id, -32602, "Missing required parameter: uri");
            }
        };

        // Parse the trace:/// URI.
        let path_part = match uri.strip_prefix(TRACE_URI_PREFIX) {
            Some(p) => p,
            None => {
                return jsonrpc_error(
                    id,
                    -32602,
                    &format!(
                        "Invalid resource URI: '{uri}'. Expected URI starting with '{TRACE_URI_PREFIX}'."
                    ),
                );
            }
        };

        // Determine resource type: check for /info suffix or /source/ infix.
        if let Some(trace_path) = path_part.strip_suffix("/info") {
            // Trace info resource.
            if let Some(trace) = loaded_traces.get(trace_path) {
                let info_json = json!({
                    "tracePath": trace_path,
                    "language": trace.language,
                    "totalEvents": trace.total_events,
                    "sourceFiles": trace.source_files,
                    "program": trace.program,
                    "workdir": trace.workdir,
                });
                let text = serde_json::to_string_pretty(&info_json)
                    .unwrap_or_else(|_| info_json.to_string());

                jsonrpc_result(
                    id,
                    json!({
                        "contents": [{
                            "uri": uri,
                            "mimeType": "application/json",
                            "text": text,
                        }]
                    }),
                )
            } else {
                jsonrpc_error(
                    id,
                    -32602,
                    &format!(
                        "Trace not found at '{trace_path}'. \
                         Please verify the trace path exists and is a valid CodeTracer \
                         trace directory. Load the trace first using the trace_info or \
                         exec_script tool."
                    ),
                )
            }
        } else if let Some(after_source) = find_source_suffix(path_part) {
            // Source file resource: trace_path is everything before /source/.
            let source_idx = path_part.len() - "/source/".len() - after_source.len();
            let trace_path = &path_part[..source_idx];
            let file_path = after_source;

            // Verify the trace is loaded.
            if !loaded_traces.contains_key(trace_path) {
                return jsonrpc_error(
                    id,
                    -32602,
                    &format!(
                        "Trace not found at '{trace_path}'. \
                         Please verify the trace path exists and is a valid CodeTracer \
                         trace directory. Load the trace first using the trace_info or \
                         exec_script tool."
                    ),
                );
            }

            // Read the source file from the daemon.
            let mut stream = match connect_to_daemon(config).await {
                Ok(s) => s,
                Err(e) => {
                    return jsonrpc_error(id, -32603, &format!("Cannot connect to daemon: {e}"));
                }
            };

            // Open the trace (idempotent).
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
                    return jsonrpc_error(id, -32603, &format!("Failed to open trace: {e}"));
                }
            };

            if open_resp.get("success").and_then(Value::as_bool) != Some(true) {
                let message = open_resp
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown error");
                return jsonrpc_error(id, -32603, &format!("Failed to open trace: {message}"));
            }

            // Read the source file via ct/py-read-source.  The daemon
            // handles this command by forwarding it to the backend as
            // ct/read-source and returning the result.  If the backend
            // does not support ct/read-source, fall back to reading
            // from the trace directory's `files/` subdirectory.
            let read_resp = dap_request(
                &mut stream,
                "ct/py-read-source",
                2,
                json!({
                    "tracePath": trace_path,
                    "path": file_path,
                }),
                10,
            )
            .await;

            let daemon_content = match &read_resp {
                Ok(r) if r.get("success").and_then(Value::as_bool) == Some(true) => {
                    let body = r.get("body").cloned().unwrap_or(json!({}));
                    Some(
                        body.get("content")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                    )
                }
                _ => None,
            };

            let content = match daemon_content {
                Some(c) => c,
                None => match read_source_from_trace_dir(trace_path, file_path) {
                    Ok(c) => c,
                    Err(fs_err) => {
                        let daemon_err = match &read_resp {
                            Err(e) => e.to_string(),
                            Ok(r) => r
                                .get("message")
                                .and_then(Value::as_str)
                                .unwrap_or("unknown error")
                                .to_string(),
                        };
                        return jsonrpc_error(
                            id,
                            -32603,
                            &format!(
                                "Failed to read source file: daemon: {daemon_err}; \
                                 filesystem fallback: {fs_err}"
                            ),
                        );
                    }
                },
            };

            jsonrpc_result(
                id,
                json!({
                    "contents": [{
                        "uri": uri,
                        "mimeType": "text/plain",
                        "text": content,
                    }]
                }),
            )
        } else {
            jsonrpc_error(
                id,
                -32602,
                &format!(
                    "Invalid resource URI: '{uri}'. \
                     Expected URI ending with '/info' or containing '/source/<file_path>'."
                ),
            )
        }
    })
}

/// Finds the file path portion after `/source/` in a URI path.
///
/// The trace path may itself contain `/source/` as a directory name, so
/// we search for the last occurrence of `/source/` to split correctly.
/// Returns `None` if `/source/` is not found.
fn find_source_suffix(path: &str) -> Option<&str> {
    // Search for "/source/" from the end to handle trace paths that might
    // contain "source" as a directory name.
    let needle = "/source/";
    path.rfind(needle).map(|idx| &path[idx + needle.len()..])
}

/// Handles `resources/templates/list` requests.
///
/// Returns parameterized URI templates that clients can use to construct
/// resource URIs for any trace path and source file.
fn handle_resource_templates_list(id: &Value) -> Value {
    jsonrpc_result(
        id,
        json!({
            "resourceTemplates": [
                {
                    "uriTemplate": "trace:///{trace_path}/info",
                    "name": "Trace Info",
                    "description": "Metadata about a trace file",
                    "mimeType": "application/json",
                },
                {
                    "uriTemplate": "trace:///{trace_path}/source/{file_path}",
                    "name": "Source File",
                    "description": "A source file from a trace",
                    "mimeType": "text/plain",
                },
            ]
        }),
    )
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
    let exe =
        std::env::current_exe().map_err(|e| format!("cannot determine current executable: {e}"))?;
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

/// Queries trace metadata from the daemon and returns a `LoadedTrace`.
///
/// Opens the trace (idempotent) and sends `ct/trace-info` to retrieve
/// language, event count, source files, program, and workdir.  This is
/// used by tool handlers to populate the `loaded_traces` cache.
async fn fetch_trace_metadata(
    config: &McpServerConfig,
    trace_path: &str,
) -> Result<LoadedTrace, String> {
    let mut stream = connect_to_daemon(config).await?;

    // Open the trace (idempotent if already open).
    let open_resp = dap_request(
        &mut stream,
        "ct/open-trace",
        1,
        json!({"tracePath": trace_path}),
        30,
    )
    .await?;

    if open_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = open_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return Err(format!("Failed to open trace: {message}"));
    }

    // Query trace info.
    let info_resp = dap_request(
        &mut stream,
        "ct/trace-info",
        2,
        json!({"tracePath": trace_path}),
        10,
    )
    .await?;

    if info_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = info_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return Err(format!("Failed to get trace info: {message}"));
    }

    let body = info_resp.get("body").cloned().unwrap_or(json!({}));

    let language = body
        .get("language")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_string();
    let total_events = body.get("totalEvents").and_then(Value::as_u64).unwrap_or(0);
    let source_files = body
        .get("sourceFiles")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    let program = body
        .get("program")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let workdir = body
        .get("workdir")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();

    Ok(LoadedTrace {
        language,
        total_events,
        source_files,
        program,
        workdir,
    })
}

/// Handles the `exec_script` tool.
///
/// Sends a `ct/exec-script` request to the daemon and returns the
/// script's stdout as the tool result.  Errors and timeouts are
/// reported via `isError: true` in the MCP response.
///
/// On success, also populates the `loaded_traces` cache (if not
/// already present) so that the trace's resources become available.
///
/// Enhanced error messages are designed to be actionable for AI agents:
/// - Trace not found: suggests checking the path
/// - Script syntax errors: includes the Python traceback
/// - Timeout: states the duration and suggests simplification
///
/// Includes `_meta.duration_ms` in the response for timing visibility.
async fn handle_exec_script(
    id: &Value,
    arguments: Option<&Value>,
    config: &McpServerConfig,
    loaded_traces: &mut HashMap<String, LoadedTrace>,
) -> Value {
    let start = Instant::now();

    let trace_path = match arguments
        .and_then(|a| a.get("trace_path"))
        .and_then(Value::as_str)
    {
        Some(p) => p,
        None => {
            return jsonrpc_result(
                id,
                tool_result_error("Missing required argument: trace_path"),
            );
        }
    };

    let script = match arguments
        .and_then(|a| a.get("script"))
        .and_then(Value::as_str)
    {
        Some(s) => s,
        None => {
            return jsonrpc_result(id, tool_result_error("Missing required argument: script"));
        }
    };

    let timeout_seconds = arguments
        .and_then(|a| a.get("timeout_seconds"))
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_SCRIPT_TIMEOUT);

    // Optional session ID for persistent debugging sessions.  When provided,
    // execution state (breakpoints, position) is preserved across calls.
    let session_id = arguments
        .and_then(|a| a.get("session_id"))
        .and_then(Value::as_str);

    let mut stream = match connect_to_daemon(config).await {
        Ok(s) => s,
        Err(e) => {
            let duration_ms = start.elapsed().as_millis();
            return jsonrpc_result(
                id,
                tool_result_error_with_timing(
                    &format!("Cannot connect to daemon: {e}"),
                    duration_ms,
                ),
            );
        }
    };

    // Send ct/exec-script to the daemon.
    // Use a generous deadline: script timeout + overhead for trace opening.
    let mut exec_args = json!({
        "tracePath": trace_path,
        "script": script,
        "timeout": timeout_seconds,
    });
    if let Some(sid) = session_id {
        exec_args["sessionId"] = json!(sid);
    }
    let resp = match dap_request(
        &mut stream,
        "ct/exec-script",
        1,
        exec_args,
        timeout_seconds + 30,
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            let duration_ms = start.elapsed().as_millis();
            // Enhanced error: check if the error suggests the trace was not found.
            let error_msg =
                if e.contains("trace") && (e.contains("not found") || e.contains("No such file")) {
                    format!(
                        "Trace not found at '{trace_path}'. \
                     Please verify the trace path exists and is a valid CodeTracer \
                     trace directory."
                    )
                } else {
                    format!("Daemon request failed: {e}")
                };
            return jsonrpc_result(id, tool_result_error_with_timing(&error_msg, duration_ms));
        }
    };

    let duration_ms = start.elapsed().as_millis();

    // Check the daemon response for success/failure.
    if resp.get("success").and_then(Value::as_bool) != Some(true) {
        let message = resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        // Enhanced error: detect "trace not found" from daemon message.
        let error_msg = if message.contains("trace")
            && (message.contains("not found") || message.contains("No such file"))
        {
            format!(
                "Trace not found at '{trace_path}'. \
                 Please verify the trace path exists and is a valid CodeTracer \
                 trace directory."
            )
        } else {
            format!("Script execution failed: {message}")
        };
        return jsonrpc_result(id, tool_result_error_with_timing(&error_msg, duration_ms));
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
            tool_result_error_with_timing(
                &format!(
                    "Script execution timed out after {timeout_seconds} seconds. \
                     Consider simplifying the script or increasing the timeout."
                ),
                duration_ms,
            ),
        );
    }

    if exit_code != 0 {
        // Script error — include both stderr and stdout so the agent
        // can see the full error context (including Python tracebacks).
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
        return jsonrpc_result(id, tool_result_error_with_timing(&error_text, duration_ms));
    }

    // On success, ensure the trace is in the loaded_traces cache.
    // This populates resources for subsequent resources/list calls.
    if !loaded_traces.contains_key(trace_path) {
        // Best-effort: if fetching metadata fails, we still return the
        // script output — the trace just won't appear in resources.
        match fetch_trace_metadata(config, trace_path).await {
            Ok(meta) => {
                loaded_traces.insert(trace_path.to_string(), meta);
            }
            Err(e) => {
                eprintln!("mcp: warning: could not cache trace metadata for resources: {e}");
            }
        }
    }

    // Success — return stdout as the tool result with timing.
    jsonrpc_result(id, tool_result_text_with_timing(stdout, duration_ms))
}

/// Handles the `trace_info` tool.
///
/// Opens the trace (if not already open) and returns metadata: language,
/// event count, source files, program, and working directory.
///
/// Also populates the `loaded_traces` cache so the trace's resources
/// become available via `resources/list`.
///
/// Includes `_meta.duration_ms` in the response for timing visibility.
async fn handle_trace_info(
    id: &Value,
    arguments: Option<&Value>,
    config: &McpServerConfig,
    loaded_traces: &mut HashMap<String, LoadedTrace>,
) -> Value {
    let start = Instant::now();

    let trace_path = match arguments
        .and_then(|a| a.get("trace_path"))
        .and_then(Value::as_str)
    {
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
            let duration_ms = start.elapsed().as_millis();
            return jsonrpc_result(
                id,
                tool_result_error_with_timing(
                    &format!("Cannot connect to daemon: {e}"),
                    duration_ms,
                ),
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
            let duration_ms = start.elapsed().as_millis();
            return jsonrpc_result(
                id,
                tool_result_error_with_timing(&format!("Failed to open trace: {e}"), duration_ms),
            );
        }
    };

    if open_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let duration_ms = start.elapsed().as_millis();
        let message = open_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return jsonrpc_result(
            id,
            tool_result_error_with_timing(&format!("Failed to open trace: {message}"), duration_ms),
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
            let duration_ms = start.elapsed().as_millis();
            return jsonrpc_result(
                id,
                tool_result_error_with_timing(
                    &format!("Failed to get trace info: {e}"),
                    duration_ms,
                ),
            );
        }
    };

    if info_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let duration_ms = start.elapsed().as_millis();
        let message = info_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return jsonrpc_result(
            id,
            tool_result_error_with_timing(
                &format!("Failed to get trace info: {message}"),
                duration_ms,
            ),
        );
    }

    let body = info_resp.get("body").cloned().unwrap_or(json!({}));

    // Cache the trace metadata for resource listing.
    let language = body
        .get("language")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_string();
    let total_events = body.get("totalEvents").and_then(Value::as_u64).unwrap_or(0);
    let source_files: Vec<String> = body
        .get("sourceFiles")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    let program = body
        .get("program")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let workdir = body
        .get("workdir")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();

    loaded_traces.insert(
        trace_path.to_string(),
        LoadedTrace {
            language: language.clone(),
            total_events,
            source_files: source_files.clone(),
            program: program.clone(),
            workdir: workdir.clone(),
        },
    );

    // Format the trace info as human-readable text for the LLM.
    let mut text = String::new();
    text.push_str("Trace Information\n");
    if let Some(path) = body.get("tracePath").and_then(Value::as_str) {
        text.push_str(&format!("  Path: {path}\n"));
    }
    text.push_str(&format!("  Language: {language}\n"));
    text.push_str(&format!("  Total events: {total_events}\n"));
    if !program.is_empty() {
        text.push_str(&format!("  Program: {program}\n"));
    }
    if !workdir.is_empty() {
        text.push_str(&format!("  Working dir: {workdir}\n"));
    }
    if !source_files.is_empty() {
        text.push_str(&format!("  Source files: ({} files)\n", source_files.len()));
        for file in &source_files {
            text.push_str(&format!("    - {file}\n"));
        }
    }

    let duration_ms = start.elapsed().as_millis();
    jsonrpc_result(id, tool_result_text_with_timing(&text, duration_ms))
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
    let start = Instant::now();

    let trace_path = match arguments
        .and_then(|a| a.get("trace_path"))
        .and_then(Value::as_str)
    {
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
            let duration_ms = start.elapsed().as_millis();
            return jsonrpc_result(
                id,
                tool_result_error_with_timing(
                    &format!("Cannot connect to daemon: {e}"),
                    duration_ms,
                ),
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
            let duration_ms = start.elapsed().as_millis();
            return jsonrpc_result(
                id,
                tool_result_error_with_timing(&format!("Failed to open trace: {e}"), duration_ms),
            );
        }
    };

    if open_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let duration_ms = start.elapsed().as_millis();
        let message = open_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return jsonrpc_result(
            id,
            tool_result_error_with_timing(&format!("Failed to open trace: {message}"), duration_ms),
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
            let duration_ms = start.elapsed().as_millis();
            return jsonrpc_result(
                id,
                tool_result_error_with_timing(
                    &format!("Failed to get trace info: {e}"),
                    duration_ms,
                ),
            );
        }
    };

    if info_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let duration_ms = start.elapsed().as_millis();
        let message = info_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return jsonrpc_result(
            id,
            tool_result_error_with_timing(
                &format!("Failed to get trace info: {message}"),
                duration_ms,
            ),
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

    let duration_ms = start.elapsed().as_millis();
    jsonrpc_result(id, tool_result_text_with_timing(&text, duration_ms))
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
    let start = Instant::now();

    let trace_path = match arguments
        .and_then(|a| a.get("trace_path"))
        .and_then(Value::as_str)
    {
        Some(p) => p,
        None => {
            return jsonrpc_result(
                id,
                tool_result_error("Missing required argument: trace_path"),
            );
        }
    };

    let file_path = match arguments
        .and_then(|a| a.get("file_path"))
        .and_then(Value::as_str)
    {
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
            let duration_ms = start.elapsed().as_millis();
            return jsonrpc_result(
                id,
                tool_result_error_with_timing(
                    &format!("Cannot connect to daemon: {e}"),
                    duration_ms,
                ),
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
            let duration_ms = start.elapsed().as_millis();
            return jsonrpc_result(
                id,
                tool_result_error_with_timing(&format!("Failed to open trace: {e}"), duration_ms),
            );
        }
    };

    if open_resp.get("success").and_then(Value::as_bool) != Some(true) {
        let duration_ms = start.elapsed().as_millis();
        let message = open_resp
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return jsonrpc_result(
            id,
            tool_result_error_with_timing(&format!("Failed to open trace: {message}"), duration_ms),
        );
    }

    // Send ct/py-read-source to the daemon.  If the backend does not
    // support the ct/read-source command (e.g. the db-backend for RR
    // traces), fall back to reading the file directly from the trace
    // directory's `files/` subdirectory, where CodeTracer stores copies
    // of all source files at recording time.
    let read_resp = dap_request(
        &mut stream,
        "ct/py-read-source",
        2,
        json!({
            "tracePath": trace_path,
            "path": file_path,
        }),
        10,
    )
    .await;

    let daemon_content = match &read_resp {
        Ok(r) if r.get("success").and_then(Value::as_bool) == Some(true) => {
            let body = r.get("body").cloned().unwrap_or(json!({}));
            Some(
                body.get("content")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string(),
            )
        }
        _ => None,
    };

    let content = match daemon_content {
        Some(c) => c,
        None => {
            // Fallback: read directly from the trace directory.
            // CodeTracer traces store source files under
            // `<trace_dir>/files/<absolute_path>`, stripping any leading `/`.
            match read_source_from_trace_dir(trace_path, file_path) {
                Ok(c) => c,
                Err(fs_err) => {
                    // Both the daemon and the filesystem fallback failed.
                    let daemon_err = match &read_resp {
                        Err(e) => e.to_string(),
                        Ok(r) => r
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown error")
                            .to_string(),
                    };
                    let duration_ms = start.elapsed().as_millis();
                    return jsonrpc_result(
                        id,
                        tool_result_error_with_timing(
                            &format!(
                                "Failed to read source file: daemon: {daemon_err}; \
                                 filesystem fallback: {fs_err}"
                            ),
                            duration_ms,
                        ),
                    );
                }
            }
        }
    };

    let duration_ms = start.elapsed().as_millis();
    jsonrpc_result(id, tool_result_text_with_timing(&content, duration_ms))
}

// ---------------------------------------------------------------------------
// Filesystem fallback for source file reading
// ---------------------------------------------------------------------------

/// Reads a source file from a trace, trying multiple resolution strategies.
///
/// This function serves as a fallback when the daemon's `ct/read-source`
/// command is not supported by the backend (e.g. db-backend for Python traces).
///
/// Resolution strategies (tried in order):
///
/// 1. **Embedded files**: Check `<trace_dir>/files/<path>`.  RR traces store
///    copies of all source files at recording time under this directory.
///    For example, `/home/user/project/main.rs` is stored at
///    `<trace_dir>/files/home/user/project/main.rs`.
///
/// 2. **Absolute path on disk**: If `file_path` is absolute and exists on disk,
///    read it directly.  This is the common case for DB traces (Python) where
///    sources are still at their original recording-time locations.
///
/// 3. **Workdir-relative**: Resolve `file_path` against the `workdir` field
///    from `trace_metadata.json` in the trace directory.
///
/// 4. **Parent-relative**: Resolve `file_path` against the trace directory's
///    parent (e.g. trace at `/tmp/foo/trace/`, source at
///    `/tmp/foo/program/src/main.py`).
fn read_source_from_trace_dir(trace_path: &str, file_path: &str) -> Result<String, String> {
    let trace_dir = std::path::Path::new(trace_path);

    // Strip the leading `/` from absolute paths so the join works correctly.
    let relative = file_path.strip_prefix('/').unwrap_or(file_path);

    // Strategy 1: Check the trace's files/ subdirectory (RR traces embed source copies here).
    let files_dir = trace_dir.join("files");
    let embedded_path = files_dir.join(relative);
    if embedded_path.exists() {
        return std::fs::read_to_string(&embedded_path)
            .map_err(|e| format!("failed to read {}: {e}", embedded_path.display()));
    }

    // Strategy 2: If the path is absolute and the file exists on disk, read it directly.
    // This is the common case for DB traces (Python) where sources are still at their
    // original recording-time locations.
    let file_path_buf = std::path::Path::new(file_path);
    if file_path_buf.is_absolute() && file_path_buf.exists() {
        return std::fs::read_to_string(file_path_buf)
            .map_err(|e| format!("failed to read {}: {e}", file_path_buf.display()));
    }

    // Strategy 3: Try resolving against the workdir from trace_metadata.json.
    let metadata_path = trace_dir.join("trace_metadata.json");
    if metadata_path.exists()
        && let Ok(metadata_str) = std::fs::read_to_string(&metadata_path)
        && let Ok(metadata) = serde_json::from_str::<Value>(&metadata_str)
        && let Some(workdir) = metadata.get("workdir").and_then(Value::as_str)
    {
        let workdir_resolved = std::path::Path::new(workdir).join(relative);
        if workdir_resolved.exists() {
            return std::fs::read_to_string(&workdir_resolved).map_err(|e| {
                format!("failed to read {}: {e}", workdir_resolved.display())
            });
        }
    }

    // Strategy 4: Try the trace directory's parent (e.g. trace at /tmp/foo/trace/,
    // source at /tmp/foo/program/src/main.py).
    if let Some(parent) = trace_dir.parent() {
        let parent_resolved = parent.join(relative);
        if parent_resolved.exists() {
            return std::fs::read_to_string(&parent_resolved)
                .map_err(|e| format!("failed to read {}: {e}", parent_resolved.display()));
        }
    }

    Err(format!(
        "source file not found: tried {}, absolute path, workdir, and parent dir",
        embedded_path.display()
    ))
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
    fn test_tool_result_text_with_timing() {
        let result = tool_result_text_with_timing("hello", 42);
        assert_eq!(result["content"][0]["type"], "text");
        assert_eq!(result["content"][0]["text"], "hello");
        assert_eq!(result["_meta"]["duration_ms"], 42);
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
    fn test_tool_result_error_with_timing() {
        let result = tool_result_error_with_timing("something went wrong", 100);
        assert_eq!(result["content"][0]["type"], "text");
        assert_eq!(result["content"][0]["text"], "something went wrong");
        assert_eq!(result["isError"], true);
        assert_eq!(result["_meta"]["duration_ms"], 100);
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
        assert!(result["capabilities"]["resources"].is_object());
    }

    #[test]
    fn test_handle_tools_list() {
        let resp = handle_tools_list(&json!(2));
        let tools = resp["result"]["tools"].as_array().expect("tools array");
        assert_eq!(tools.len(), 4);

        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"exec_script"));
        assert!(names.contains(&"trace_info"));
        assert!(names.contains(&"list_source_files"));
        assert!(names.contains(&"read_source_file"));

        // Verify each tool has an inputSchema.
        for tool in tools {
            assert!(
                tool.get("inputSchema").is_some(),
                "tool missing inputSchema"
            );
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
        let resp = handle_prompts_get(&json!(4), Some(&json!({"name": "trace_query_api"})));
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
            text.len() < 15 * 1024,
            "API reference is {} bytes, should be under 15KB",
            text.len()
        );
    }

    #[test]
    fn test_api_reference_is_under_300_lines() {
        let text = trace_query_api_reference();
        let lines = text.lines().count();
        assert!(
            lines < 400,
            "API reference is {lines} lines, should be under 400",
        );
    }

    #[test]
    fn test_handle_resources_list_empty() {
        let loaded = HashMap::new();
        let resp = handle_resources_list(&json!(10), &loaded);
        let resources = resp["result"]["resources"]
            .as_array()
            .expect("resources array");
        assert!(resources.is_empty());
    }

    #[test]
    fn test_handle_resources_list_with_loaded_trace() {
        let mut loaded = HashMap::new();
        loaded.insert(
            "/tmp/test-trace".to_string(),
            LoadedTrace {
                language: "nim".to_string(),
                total_events: 42,
                source_files: vec!["src/main.nim".to_string(), "src/lib.nim".to_string()],
                program: "main.nim".to_string(),
                workdir: "/tmp/work".to_string(),
            },
        );

        let resp = handle_resources_list(&json!(11), &loaded);
        let resources = resp["result"]["resources"]
            .as_array()
            .expect("resources array");

        // Should have 1 info resource + 2 source file resources = 3 total.
        assert_eq!(resources.len(), 3);

        // Verify the info resource.
        assert_eq!(resources[0]["uri"], "trace:///tmp/test-trace/info");
        assert_eq!(resources[0]["mimeType"], "application/json");

        // Verify source file resources.
        assert_eq!(
            resources[1]["uri"],
            "trace:///tmp/test-trace/source/src/main.nim"
        );
        assert_eq!(resources[1]["mimeType"], "text/plain");
        assert_eq!(
            resources[2]["uri"],
            "trace:///tmp/test-trace/source/src/lib.nim"
        );
    }

    #[test]
    fn test_handle_resource_templates_list() {
        let resp = handle_resource_templates_list(&json!(12));
        let templates = resp["result"]["resourceTemplates"]
            .as_array()
            .expect("resourceTemplates array");
        assert_eq!(templates.len(), 2);

        assert_eq!(templates[0]["uriTemplate"], "trace:///{trace_path}/info");
        assert_eq!(templates[0]["mimeType"], "application/json");

        assert_eq!(
            templates[1]["uriTemplate"],
            "trace:///{trace_path}/source/{file_path}"
        );
        assert_eq!(templates[1]["mimeType"], "text/plain");
    }

    #[test]
    fn test_find_source_suffix() {
        // Normal case.
        assert_eq!(
            find_source_suffix("/tmp/trace/source/main.nim"),
            Some("main.nim")
        );

        // Nested path after /source/.
        assert_eq!(
            find_source_suffix("/tmp/trace/source/src/lib.nim"),
            Some("src/lib.nim")
        );

        // No /source/ present.
        assert_eq!(find_source_suffix("/tmp/trace/info"), None);

        // Trace path containing "source" directory.
        assert_eq!(
            find_source_suffix("/home/source/project/trace/source/main.nim"),
            Some("main.nim")
        );
    }

    #[test]
    fn test_read_source_from_trace_dir_success() {
        // Create a temporary trace directory with a source file.
        let tmp = std::env::temp_dir().join("ct-test-read-source-success");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("files/home/user")).unwrap();
        std::fs::write(tmp.join("files/home/user/main.rs"), "fn main() {}").unwrap();

        let result = read_source_from_trace_dir(tmp.to_str().unwrap(), "/home/user/main.rs");
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "fn main() {}");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_read_source_from_trace_dir_strips_leading_slash() {
        // Verify that both "/home/user/main.rs" and "home/user/main.rs"
        // resolve to the same file under `files/`.
        let tmp = std::env::temp_dir().join("ct-test-read-source-slash");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("files/home/user")).unwrap();
        std::fs::write(tmp.join("files/home/user/main.rs"), "fn main() {}").unwrap();

        let with_slash = read_source_from_trace_dir(tmp.to_str().unwrap(), "/home/user/main.rs");
        let without_slash = read_source_from_trace_dir(tmp.to_str().unwrap(), "home/user/main.rs");

        assert_eq!(with_slash.unwrap(), "fn main() {}");
        assert_eq!(without_slash.unwrap(), "fn main() {}");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_read_source_from_trace_dir_missing_file() {
        let tmp = std::env::temp_dir().join("ct-test-read-source-missing");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("files")).unwrap();

        let result = read_source_from_trace_dir(tmp.to_str().unwrap(), "/nonexistent/file.rs");
        assert!(result.is_err());
        let err_msg = result.unwrap_err();
        assert!(
            err_msg.contains("not found"),
            "error should mention 'not found', got: {err_msg}"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_read_source_from_trace_dir_absolute_path_fallback() {
        // Strategy 2: If the file_path is absolute and exists on disk, read it directly.
        // This simulates a DB trace (Python) where source files are at their original
        // locations.
        let tmp = std::env::temp_dir().join("ct-test-read-source-absolute");
        let _ = std::fs::remove_dir_all(&tmp);
        let trace_dir = tmp.join("trace");
        std::fs::create_dir_all(&trace_dir).unwrap();

        // Create a source file at an absolute path outside the trace dir.
        let source_dir = tmp.join("project");
        std::fs::create_dir_all(&source_dir).unwrap();
        std::fs::write(source_dir.join("main.py"), "print('hello')").unwrap();

        let source_path = source_dir.join("main.py");
        let result = read_source_from_trace_dir(
            trace_dir.to_str().unwrap(),
            source_path.to_str().unwrap(),
        );
        assert!(result.is_ok(), "expected Ok, got: {:?}", result);
        assert_eq!(result.unwrap(), "print('hello')");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_read_source_from_trace_dir_workdir_fallback() {
        // Strategy 3: Resolve relative paths against the workdir from trace_metadata.json.
        let tmp = std::env::temp_dir().join("ct-test-read-source-workdir");
        let _ = std::fs::remove_dir_all(&tmp);
        let trace_dir = tmp.join("trace");
        std::fs::create_dir_all(&trace_dir).unwrap();

        // Create the source file under a separate workdir.
        let workdir = tmp.join("workdir");
        std::fs::create_dir_all(workdir.join("src")).unwrap();
        std::fs::write(workdir.join("src/app.py"), "import os").unwrap();

        // Write trace_metadata.json with the workdir field.
        let metadata = serde_json::json!({
            "workdir": workdir.to_str().unwrap(),
            "language": "python"
        });
        std::fs::write(
            trace_dir.join("trace_metadata.json"),
            serde_json::to_string(&metadata).unwrap(),
        )
        .unwrap();

        let result = read_source_from_trace_dir(trace_dir.to_str().unwrap(), "src/app.py");
        assert!(result.is_ok(), "expected Ok, got: {:?}", result);
        assert_eq!(result.unwrap(), "import os");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_read_source_from_trace_dir_parent_fallback() {
        // Strategy 4: Resolve relative paths against the trace directory's parent.
        let tmp = std::env::temp_dir().join("ct-test-read-source-parent");
        let _ = std::fs::remove_dir_all(&tmp);
        let trace_dir = tmp.join("trace");
        std::fs::create_dir_all(&trace_dir).unwrap();

        // Create a source file next to the trace dir, under the parent.
        std::fs::create_dir_all(tmp.join("program/src")).unwrap();
        std::fs::write(tmp.join("program/src/main.py"), "x = 1").unwrap();

        let result =
            read_source_from_trace_dir(trace_dir.to_str().unwrap(), "program/src/main.py");
        assert!(result.is_ok(), "expected Ok, got: {:?}", result);
        assert_eq!(result.unwrap(), "x = 1");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_read_source_from_trace_dir_strategy_priority() {
        // When a file exists both in files/ and at its absolute path, the embedded
        // copy (strategy 1) should win.
        let tmp = std::env::temp_dir().join("ct-test-read-source-priority");
        let _ = std::fs::remove_dir_all(&tmp);
        let trace_dir = tmp.join("trace");
        std::fs::create_dir_all(&trace_dir).unwrap();

        // Create the "real" source file on disk.
        let source_dir = tmp.join("src");
        std::fs::create_dir_all(&source_dir).unwrap();
        std::fs::write(source_dir.join("lib.py"), "# disk version").unwrap();

        // Also embed it under files/.
        let abs_source = source_dir.join("lib.py");
        let relative = abs_source
            .to_str()
            .unwrap()
            .strip_prefix('/')
            .unwrap();
        let embedded = trace_dir.join("files").join(relative);
        std::fs::create_dir_all(embedded.parent().unwrap()).unwrap();
        std::fs::write(&embedded, "# embedded version").unwrap();

        let result = read_source_from_trace_dir(
            trace_dir.to_str().unwrap(),
            abs_source.to_str().unwrap(),
        );
        assert!(result.is_ok(), "expected Ok, got: {:?}", result);
        assert_eq!(
            result.unwrap(),
            "# embedded version",
            "strategy 1 (embedded) should take priority over strategy 2 (absolute)"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
