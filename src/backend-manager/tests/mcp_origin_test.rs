//! Integration tests for the M8 Value Origin Tracking surfaces:
//!
//! - `get_value_origin` MCP tool — registration, schema, description.
//! - `resolve_variable_step` MCP tool — registration + schema.
//! - `ct trace origin` CLI subcommand — registration only (the full
//!   roundtrip needs a live daemon + recorder).
//! - End-to-end runs of both tools against the canonical
//!   `simple_trivial_chain` Python fixture, recorded for real.
//!
//! The end-to-end tests drive the actual `backend-manager` binary as a
//! subprocess speaking the MCP JSON-RPC protocol on stdin/stdout,
//! against a daemon running a real `replay-server` over a real
//! recording. That is deliberate: `get_value_origin` and
//! `resolve_variable_step` were advertised by `tools/list` while
//! `tools/call` answered `-32602 Unknown tool`, and every layer beneath
//! the MCP surface was green throughout. Only a test that goes through
//! `tools/call` can see that defect.
//!
//! SKIP discipline mirrors M3/M5/M6: narrow probes only, no broad
//! heuristics. When the Python recorder or `replay-server` is
//! unavailable we emit a `SKIPPED: <precise reason>` line on stderr and
//! `return` — never `panic!`. A recorder that runs and *fails*, by
//! contrast, is a hard error. Genuine M8 bugs surface as failures.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

use serde_json::{Value, json};

// ---------------------------------------------------------------------------
// SKIP discipline
// ---------------------------------------------------------------------------

fn skip(reason: &str) {
    eprintln!("SKIPPED: {reason}");
}

/// Find the `backend-manager` binary under the workspace's `target/`
/// directory. Returns `None` (with a SKIP line printed) when the binary
/// hasn't been built yet — this happens on fresh checkouts before
/// `cargo build` runs in this crate.
fn find_binary() -> Option<PathBuf> {
    // The crate is named `session-manager` in Cargo.toml; the binary
    // name follows the package name unless `[[bin]]` overrides it.
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        // Walk up from the test binary's location to find the
        // surrounding `target/` directory: $TARGET/<profile>/deps/<test>.
        let mut p: PathBuf = exe;
        for _ in 0..4 {
            p.pop();
            for name in ["session-manager", "backend-manager"] {
                let candidate = p.join(name);
                if candidate.is_file() {
                    candidates.push(candidate);
                }
            }
        }
    }

    candidates.into_iter().find(|p| p.exists())
}

/// Find the path to the `simple_trivial_chain` Python fixture so a
/// genuine recorder run (when available) can produce a `.ct` trace.
fn fixture_source(scenario: &str) -> PathBuf {
    // CARGO_MANIFEST_DIR points at `src/backend-manager`.
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR is set by cargo for integration tests");
    let manifest = PathBuf::from(manifest_dir);
    manifest
        .parent()
        .and_then(Path::parent)
        .map(|p| {
            p.join("src/db-backend/tests/fixtures/origin/python")
                .join(scenario)
                .join("main.py")
        })
        .unwrap_or_else(|| PathBuf::from(scenario))
}

fn python_recorder_installed() -> bool {
    // Narrow probe: the recorder lives at $CODETRACER_PYTHON_RECORDER_PATH
    // or as `codetracer-python-recorder` on `PATH`. Either is enough
    // for the harness, but we only need to confirm presence to decide
    // whether the end-to-end SKIP fires.
    if std::env::var("CODETRACER_PYTHON_RECORDER_PATH").is_ok() {
        return true;
    }
    Command::new("codetracer-python-recorder")
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .ok()
        .map(|s| s.success())
        .unwrap_or(false)
}

// ---------------------------------------------------------------------------
// MCP client over stdio
// ---------------------------------------------------------------------------

/// A minimal MCP client that speaks JSON-RPC 2.0 over the subprocess's
/// stdio pipes. The MCP server reads newline-delimited JSON, so the
/// client writes one message per line and reads the same way.
struct McpClient {
    child: Child,
    stdin: std::process::ChildStdin,
    reader: BufReader<std::process::ChildStdout>,
    next_id: AtomicI64,
}

impl McpClient {
    /// Spawn an MCP server with no daemon wired up — enough for the
    /// schema / registration tests, which never touch a trace.
    fn spawn(binary: &Path) -> Result<Self, String> {
        Self::spawn_inner(binary, None)
    }

    /// Spawn an MCP server pointed at a specific daemon socket, so tool
    /// calls reach a real `replay-server` over a real recording.
    fn spawn_with_daemon(binary: &Path, socket: &Path) -> Result<Self, String> {
        Self::spawn_inner(binary, Some(socket))
    }

    fn spawn_inner(binary: &Path, socket: Option<&Path>) -> Result<Self, String> {
        let mut command = Command::new(binary);
        command
            .args(["trace", "mcp"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        if let Some(socket) = socket {
            command.env("CODETRACER_DAEMON_SOCK", socket);
        }
        let mut child = command
            .spawn()
            .map_err(|e| format!("failed to spawn `{} trace mcp`: {e}", binary.display()))?;
        let stdin = child.stdin.take().ok_or("no stdin on MCP subprocess")?;
        let stdout = child.stdout.take().ok_or("no stdout on MCP subprocess")?;

        let mut client = McpClient {
            child,
            stdin,
            reader: BufReader::new(stdout),
            next_id: AtomicI64::new(1),
        };
        client.initialize()?;
        Ok(client)
    }

    fn initialize(&mut self) -> Result<(), String> {
        let id = self.send_request("initialize", json!({}))?;
        let response = self.read_response(id)?;
        if response.get("result").is_none() {
            return Err(format!("initialize returned no result: {response}"));
        }
        // MCP requires a `notifications/initialized` follow-up.
        let msg = json!({
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": {},
        });
        self.write_message(&msg)?;
        Ok(())
    }

    fn send_request(&mut self, method: &str, params: Value) -> Result<i64, String> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let msg = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });
        self.write_message(&msg)?;
        Ok(id)
    }

    fn write_message(&mut self, msg: &Value) -> Result<(), String> {
        let serialized = serde_json::to_string(msg).map_err(|e| format!("serialize: {e}"))?;
        writeln!(self.stdin, "{serialized}").map_err(|e| format!("write: {e}"))?;
        self.stdin.flush().map_err(|e| format!("flush: {e}"))?;
        Ok(())
    }

    fn read_response(&mut self, expected_id: i64) -> Result<Value, String> {
        loop {
            let mut line = String::new();
            let n = self
                .reader
                .read_line(&mut line)
                .map_err(|e| format!("read: {e}"))?;
            if n == 0 {
                return Err("MCP subprocess closed stdout".to_string());
            }
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let value: Value = serde_json::from_str(trimmed)
                .map_err(|e| format!("invalid JSON: {e}: {trimmed}"))?;
            let response_id = value.get("id").and_then(Value::as_i64).unwrap_or(-1);
            if response_id == expected_id {
                return Ok(value);
            }
            // Skip notifications and unrelated responses.
        }
    }

    fn call_tool(&mut self, name: &str, arguments: Value) -> Result<Value, String> {
        let id = self.send_request("tools/call", json!({"name": name, "arguments": arguments}))?;
        self.read_response(id)
    }

    fn list_tools(&mut self) -> Result<Value, String> {
        let id = self.send_request("tools/list", json!({}))?;
        self.read_response(id)
    }
}

impl Drop for McpClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

// ---------------------------------------------------------------------------
// Schema / description tests — these are the ones that MUST always pass.
// They don't require a live daemon or a recorder; they only verify that
// the MCP server registers the M8 tools with the right shapes.
// ---------------------------------------------------------------------------

fn extract_tool<'a>(tools: &'a Value, name: &str) -> Option<&'a Value> {
    tools
        .get("result")
        .and_then(|r| r.get("tools"))
        .and_then(Value::as_array)
        .and_then(|arr| {
            arr.iter()
                .find(|t| t.get("name").and_then(Value::as_str) == Some(name))
        })
}

#[test]
fn test_mcp_get_value_origin_description_points_at_scripting() {
    let Some(binary) = find_binary() else {
        skip("backend-manager binary not yet built");
        return;
    };
    let mut client = match McpClient::spawn(&binary) {
        Ok(c) => c,
        Err(e) => {
            skip(&format!("cannot spawn MCP subprocess: {e}"));
            return;
        }
    };
    let tools = client.list_tools().expect("tools/list should succeed");
    let tool = extract_tool(&tools, "get_value_origin")
        .unwrap_or_else(|| panic!("get_value_origin tool missing from tools/list: {tools}"));
    let description = tool
        .get("description")
        .and_then(Value::as_str)
        .unwrap_or("");
    // The description MUST steer callers toward the scripting workflow.
    assert!(
        description.contains("exec_script"),
        "get_value_origin description must reference the exec_script scripting workflow (got: {description})"
    );
    assert!(
        description.contains("value_origin"),
        "get_value_origin description must mention the trace.value_origin method (got: {description})"
    );
}

#[test]
fn test_mcp_resolve_variable_step_tool_registered() {
    let Some(binary) = find_binary() else {
        skip("backend-manager binary not yet built");
        return;
    };
    let mut client = match McpClient::spawn(&binary) {
        Ok(c) => c,
        Err(e) => {
            skip(&format!("cannot spawn MCP subprocess: {e}"));
            return;
        }
    };
    let tools = client.list_tools().expect("tools/list should succeed");
    let tool = extract_tool(&tools, "resolve_variable_step")
        .unwrap_or_else(|| panic!("resolve_variable_step tool missing: {tools}"));
    // Input schema must require trace_path + variable.
    let required = tool
        .get("inputSchema")
        .and_then(|s| s.get("required"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    assert!(
        required.contains(&"trace_path".to_string()),
        "resolve_variable_step must require trace_path"
    );
    assert!(
        required.contains(&"variable".to_string()),
        "resolve_variable_step must require variable"
    );
}

// ---------------------------------------------------------------------------
// End-to-end tests — gated on the recorder being installed.
//
// These drive the REAL surface an MCP client sees: the `trace mcp`
// subprocess, speaking JSON-RPC on stdio, against a daemon running a real
// `replay-server` over a real recording.  That matters here specifically:
// `get_value_origin` and `resolve_variable_step` were advertised by
// `tools/list` for several releases while `tools/call` answered
// `-32602 Unknown tool`, and every layer *beneath* the MCP surface —
// the classifier, `ct/originChain`, the per-language
// `origin_*_dap_test.rs` suites — was green the whole time.  A test that
// called the classifier directly would have proved nothing.
// ---------------------------------------------------------------------------

/// Locate a built `replay-server`, mirroring the probe in
/// `real_recording_integration.rs`.
fn find_replay_server() -> Option<PathBuf> {
    let mut target_dir = std::env::current_exe().ok()?;
    target_dir.pop();
    if target_dir.ends_with("deps") {
        target_dir.pop();
    }
    for name in ["replay-server", "db-backend"] {
        let candidate = target_dir.join(format!("{}{}", name, std::env::consts::EXE_SUFFIX));
        if candidate.exists() {
            return Some(candidate);
        }
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let exe = std::env::consts::EXE_SUFFIX;
    for relative in [
        format!("../db-backend/target/debug/replay-server{exe}"),
        format!("../db-backend/target/release/replay-server{exe}"),
        format!("../build-debug/bin/replay-server{exe}"),
    ] {
        let path = manifest_dir.join(&relative);
        if path.exists() {
            return Some(path.canonicalize().unwrap_or(path));
        }
    }

    if let Ok(from_env) = std::env::var("CODETRACER_REPLAY_SERVER_CMD") {
        let path = PathBuf::from(from_env);
        if path.exists() {
            return Some(path);
        }
    }

    None
}

/// The Python interpreter to drive the recorder with.
fn python_command() -> String {
    std::env::var("CODETRACER_PYTHON_CMD")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            ["python3.12", "python3.13", "python3", "python"]
                .iter()
                .find(|cmd| {
                    Command::new(cmd)
                        .arg("--version")
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .status()
                        .map(|s| s.success())
                        .unwrap_or(false)
                })
                .copied()
                .unwrap_or("python3")
                .to_string()
        })
}

/// Record the named Python fixture and return the directory holding the
/// resulting `.ct` container.
///
/// Returns `None` (with a `SKIPPED:` line) only for narrow, precisely
/// identified environment problems — the recorder module not being
/// importable, or the fixture source having moved.  A recorder that runs
/// and fails is a hard error: that is a real bug, not an environment
/// gap.
fn record_python_fixture(scenario: &str) -> Option<PathBuf> {
    let source = fixture_source(scenario);
    if !source.exists() {
        skip(&format!(
            "fixture source not found at {} (CT_REPO sibling missing?)",
            source.display()
        ));
        return None;
    }

    let python = python_command();
    let importable = Command::new(&python)
        .args(["-c", "import codetracer_python_recorder"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !importable && !python_recorder_installed() {
        skip(
            "Python recorder not importable (install codetracer-python-recorder or set CODETRACER_PYTHON_RECORDER_PATH)",
        );
        return None;
    }

    // Short path: the daemon's Unix socket lives beside the trace, and an
    // over-long socket path fails with `SUN_LEN`.
    let root =
        PathBuf::from("/tmp").join(format!("ct-mcp-origin-{}-{}", std::process::id(), scenario));
    let _ = std::fs::remove_dir_all(&root);
    let trace_dir = root.join("trace");
    std::fs::create_dir_all(&trace_dir).expect("cannot create trace dir");

    // Record from a copy so the recorded source path lives beside the
    // trace, which is where the DAP server resolves breakpoints from.
    let source_copy = trace_dir.join("main.py");
    std::fs::copy(&source, &source_copy).expect("cannot copy fixture source");

    let output = Command::new(&python)
        .args([
            "-m",
            "codetracer_python_recorder",
            "--out-dir",
            trace_dir.to_str().unwrap(),
            source_copy.to_str().unwrap(),
        ])
        .current_dir(&trace_dir)
        .env("CODETRACER_TRACE_FORMAT", "ctfs")
        .output()
        .expect("failed to spawn the Python recorder");
    assert!(
        output.status.success(),
        "recording {scenario} failed:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let produced_ct = std::fs::read_dir(&trace_dir)
        .ok()
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .any(|e| e.path().extension().is_some_and(|ext| ext == "ct"))
        })
        .unwrap_or(false);
    if !produced_ct {
        skip(&format!(
            "recorder produced no .ct container in {} (native extension missing?)",
            trace_dir.display()
        ));
        return None;
    }

    Some(trace_dir)
}

/// A daemon running a real `replay-server`, torn down on drop.
struct TestDaemon {
    child: Child,
    socket: PathBuf,
}

impl Drop for TestDaemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_file(&self.socket);
    }
}

/// Start a daemon whose socket lives under `root`, backed by a real
/// `replay-server`.  Returns `None` (with a `SKIPPED:` line) when no
/// `replay-server` has been built.
fn start_daemon(binary: &Path, root: &Path) -> Option<TestDaemon> {
    let replay_server = match find_replay_server() {
        Some(p) => p,
        None => {
            skip(
                "replay-server not built (cargo build --bin replay-server in src/db-backend), \
                 so no real trace can be opened",
            );
            return None;
        }
    };

    let socket = root.join("daemon.sock");
    let _ = std::fs::remove_file(&socket);

    let child = Command::new(binary)
        .args(["daemon", "start"])
        .env("CODETRACER_DAEMON_SOCKET", &socket)
        .env("CODETRACER_REPLAY_SERVER_CMD", &replay_server)
        .env("TMPDIR", root)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("cannot spawn daemon");

    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while std::time::Instant::now() < deadline {
        if socket.exists() {
            return Some(TestDaemon { child, socket });
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    let mut daemon = TestDaemon { child, socket };
    let _ = daemon.child.kill();
    panic!("daemon socket never appeared within 20s");
}

/// Everything an end-to-end origin test needs: a recorded trace, a live
/// daemon, and an MCP client wired to it.
struct OriginHarness {
    _daemon: TestDaemon,
    client: McpClient,
    trace_path: String,
}

/// Build the harness for `scenario`, or return `None` after emitting a
/// `SKIPPED:` line explaining precisely what was missing.
fn origin_harness(scenario: &str) -> Option<OriginHarness> {
    let binary = match find_binary() {
        Some(b) => b,
        None => {
            skip("backend-manager binary not yet built");
            return None;
        }
    };
    let trace_dir = record_python_fixture(scenario)?;
    let root = trace_dir
        .parent()
        .expect("trace dir has a parent")
        .to_path_buf();
    let daemon = start_daemon(&binary, &root)?;

    let client = match McpClient::spawn_with_daemon(&binary, &daemon.socket) {
        Ok(c) => c,
        Err(e) => panic!("cannot spawn MCP subprocess: {e}"),
    };

    Some(OriginHarness {
        _daemon: daemon,
        client,
        trace_path: trace_dir.to_string_lossy().to_string(),
    })
}

/// Unwrap a `tools/call` result into its text content, asserting the call
/// did not come back as a tool error.
fn expect_tool_text(response: &Value, what: &str) -> String {
    assert!(
        response.get("error").is_none(),
        "{what} returned a JSON-RPC error (an advertised tool must at least dispatch): {response}"
    );
    let result = response
        .get("result")
        .unwrap_or_else(|| panic!("{what} returned neither result nor error: {response}"));
    let text = result
        .get("content")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|c| c.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default();
    assert_ne!(
        result.get("isError").and_then(Value::as_bool),
        Some(true),
        "{what} failed: {text}"
    );
    text
}

/// The canonical `simple_trivial_chain` answer, end to end through the
/// MCP surface: `c -> b -> a -> Literal(10)`.
///
/// Asserted against `tests/fixtures/origin/python/simple_trivial_chain/ANSWERS.md`.
#[test]
fn test_mcp_get_value_origin_returns_canonical_chain() {
    let Some(mut harness) = origin_harness("simple_trivial_chain") else {
        return;
    };

    let response = harness
        .client
        .call_tool(
            "get_value_origin",
            json!({
                "trace_path": harness.trace_path,
                "path": "main.py",
                "line": 12,
                "variable": "c",
            }),
        )
        .expect("get_value_origin call should complete");
    let text = expect_tool_text(&response, "get_value_origin");

    // The tool appends the canonical wire body after the rendered chain.
    let json_start = text
        .find('{')
        .unwrap_or_else(|| panic!("no canonical JSON in get_value_origin output: {text}"));
    let chain: Value = serde_json::from_str(text[json_start..].trim()).unwrap_or_else(|e| {
        panic!(
            "canonical JSON did not parse ({e}): {}",
            &text[json_start..]
        )
    });

    let hops = chain
        .get("hops")
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("chain has no hops array: {chain}"));
    assert_eq!(
        hops.len(),
        3,
        "ANSWERS.md expects c -> b -> a; got {} hops: {chain}",
        hops.len()
    );
    let kinds: Vec<&str> = hops
        .iter()
        .filter_map(|h| h.get("kind").and_then(Value::as_str))
        .collect();
    assert_eq!(
        kinds,
        vec!["trivialCopy", "trivialCopy", "literal"],
        "unexpected hop kinds: {chain}"
    );
    let sources: Vec<&str> = hops
        .iter()
        .filter_map(|h| h.get("sourceText").and_then(Value::as_str))
        .map(str::trim)
        .collect();
    assert_eq!(
        sources,
        vec!["c = b", "b = a", "a = 10"],
        "unexpected assigning statements: {chain}"
    );
    assert_eq!(
        chain
            .get("terminator")
            .and_then(|t| t.get("kind"))
            .and_then(Value::as_str),
        Some("literal"),
        "ANSWERS.md expects a Literal terminator: {chain}"
    );
    assert_eq!(
        chain
            .get("terminator")
            .and_then(|t| t.get("expression"))
            .and_then(Value::as_str),
        Some("10"),
        "ANSWERS.md expects the chain to terminate at the literal 10: {chain}"
    );
}

/// `resolve_variable_step` answers the first hop.
///
/// Queried for `a` at the `print(c)` line, the answer must point back at
/// the `a = 10` assignment — not at the query line, which would mean the
/// tool had merely echoed its own input.
#[test]
fn test_mcp_resolve_variable_step_finds_latest_step() {
    let Some(mut harness) = origin_harness("simple_trivial_chain") else {
        return;
    };

    let response = harness
        .client
        .call_tool(
            "resolve_variable_step",
            json!({
                "trace_path": harness.trace_path,
                "path": "main.py",
                "line": 12,
                "variable": "a",
            }),
        )
        .expect("resolve_variable_step call should complete");
    let text = expect_tool_text(&response, "resolve_variable_step");
    let answer: Value = serde_json::from_str(text.trim())
        .unwrap_or_else(|e| panic!("resolve_variable_step output did not parse ({e}): {text}"));

    assert_eq!(
        answer.get("variable").and_then(Value::as_str),
        Some("a"),
        "answer must name the queried variable: {answer}"
    );
    assert_eq!(
        answer
            .get("assignment")
            .and_then(Value::as_str)
            .map(str::trim),
        Some("a = 10"),
        "answer must name the statement that produced the value: {answer}"
    );
    assert_eq!(
        answer.get("originKind").and_then(Value::as_str),
        Some("literal"),
        "`a = 10` is a literal assignment: {answer}"
    );

    // The reported step must be strictly before the query line, or the
    // tool has told the caller nothing it did not already supply.
    let line = answer
        .get("location")
        .and_then(|l| l.get("line"))
        .and_then(Value::as_i64)
        .unwrap_or_else(|| panic!("answer carries no location line: {answer}"));
    assert!(
        line < 12,
        "the resolved step must precede the query line 12, got {line}: {answer}"
    );
}

/// A variable that is never assigned must produce an explicit failure.
///
/// An empty-but-successful answer is indistinguishable from an
/// unimplemented tool, which is precisely the defect these tools shipped
/// with; this test pins the distinction.
#[test]
fn test_mcp_resolve_variable_step_reports_missing_variable_explicitly() {
    let Some(mut harness) = origin_harness("simple_trivial_chain") else {
        return;
    };

    let response = harness
        .client
        .call_tool(
            "resolve_variable_step",
            json!({
                "trace_path": harness.trace_path,
                "path": "main.py",
                "line": 12,
                "variable": "no_such_variable",
            }),
        )
        .expect("resolve_variable_step call should complete");

    let result = response
        .get("result")
        .unwrap_or_else(|| panic!("expected a tool result: {response}"));
    assert_eq!(
        result.get("isError").and_then(Value::as_bool),
        Some(true),
        "an unresolvable variable must be reported as a tool error, not as an empty success: {response}"
    );
    let text = result
        .get("content")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|c| c.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default();
    assert!(
        text.contains("no_such_variable"),
        "the error must name the variable that could not be resolved: {text}"
    );
}

/// A breakpoint that is never hit must not be answered about.
///
/// Line 3 is a comment: the replay runs to the end of the recording
/// instead of stopping there.  Answering with whatever chain the final
/// step happens to yield would be a wrong answer dressed as a right one.
#[test]
fn test_mcp_get_value_origin_refuses_an_unreached_line() {
    let Some(mut harness) = origin_harness("simple_trivial_chain") else {
        return;
    };

    let response = harness
        .client
        .call_tool(
            "get_value_origin",
            json!({
                "trace_path": harness.trace_path,
                "path": "main.py",
                "line": 3,
                "variable": "c",
            }),
        )
        .expect("get_value_origin call should complete");
    let result = response
        .get("result")
        .unwrap_or_else(|| panic!("expected a tool result: {response}"));
    assert_eq!(
        result.get("isError").and_then(Value::as_bool),
        Some(true),
        "a line the recording never reaches must be an error: {response}"
    );
}

/// The scripting path the `get_value_origin` description points at must
/// work too: `exec_script` running `trace.value_origin(...)`.
///
/// `ct/py-origin-chain` had a Python client, a response formatter and a
/// pending-request variant, but no route in the daemon's dispatch — so
/// every call raised `TraceError`.  This drives it through the MCP
/// surface end to end.
#[test]
fn test_mcp_exec_script_trace_value_origin_returns_chain() {
    let Some(mut harness) = origin_harness("simple_trivial_chain") else {
        return;
    };

    // Step 7 is the `print(c)` step for this fixture — the same query
    // point `get_value_origin` reaches via its breakpoint.
    let script = r#"
trace.goto_ticks(7)
chain = trace.value_origin("c")
print("HOPS", len(chain.hops))
print("TERMINATOR", chain.terminator.kind.value)
"#;

    let response = harness
        .client
        .call_tool(
            "exec_script",
            json!({ "trace_path": harness.trace_path, "script": script }),
        )
        .expect("exec_script call should complete");
    let text = expect_tool_text(&response, "exec_script + trace.value_origin");

    assert!(
        text.contains("HOPS 3"),
        "trace.value_origin should walk c -> b -> a: {text}"
    );
    assert!(
        text.contains("TERMINATOR literal"),
        "trace.value_origin should terminate at the literal 10: {text}"
    );
}

#[test]
fn test_cli_trace_exec_script_value_origin() {
    let Some(binary) = find_binary() else {
        skip("backend-manager binary not yet built");
        return;
    };
    // Verify the CLI surface — `ct trace exec --help` lists `--script`.
    let output = match Command::new(&binary)
        .args(["trace", "exec", "--help"])
        .output()
    {
        Ok(o) => o,
        Err(e) => {
            skip(&format!("cannot run `trace exec --help`: {e}"));
            return;
        }
    };
    assert!(
        output.status.success(),
        "`trace exec --help` exited with {} (stderr: {})",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    let help = String::from_utf8_lossy(&output.stdout);
    assert!(
        help.contains("--script"),
        "`ct trace exec` should advertise --script <PATH>: {help}"
    );
    assert!(
        help.contains("<TRACE_PATH>") || help.to_lowercase().contains("trace_path"),
        "`ct trace exec` should take a trace path positional: {help}"
    );
}
