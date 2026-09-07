//! Integration tests for the M8 Value Origin Tracking surfaces:
//!
//! - `get_value_origin` MCP tool — registration, schema, description.
//! - `resolve_variable_step` MCP tool — registration + schema.
//! - `ct trace origin` CLI subcommand — the full `--format
//!   json|markdown|text` roundtrip against a live daemon + a real
//!   recording.
//! - End-to-end runs of both tools against the canonical
//!   `simple_trivial_chain` Python fixture, recorded for real.
//!
//! The `--format` tests exist because `run_trace_origin`'s three output
//! arms had no coverage of any kind: `render_text` / `render_markdown`
//! are unit-tested inside `origin_renderer.rs` against a hand-built
//! `json!` fixture, but nothing proved the CLI selects the right arm,
//! and `--format json` has no renderer function at all — it is an
//! inline `serde_json::to_string_pretty` in `main.rs` that no test ever
//! looked at. These drive the real binary over a real chain.
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

/// Discriminator for per-test fixture roots — see `record_python_fixture`.
static FIXTURE_SEQ: AtomicI64 = AtomicI64::new(0);

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
    //
    // The sequence number matters: `cargo test` runs the tests in this
    // file on parallel threads of ONE process, so a root keyed only by
    // pid + scenario is shared by every test asking for the same
    // fixture — and the `remove_dir_all` below would delete a trace
    // another thread's daemon has open.
    let seq = FIXTURE_SEQ.fetch_add(1, Ordering::SeqCst);
    let root = PathBuf::from("/tmp").join(format!(
        "ct-mcp-origin-{}-{}-{seq}",
        std::process::id(),
        scenario
    ));
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
    // Pin the *reason*, not merely "some error": otherwise a transport or
    // wire-schema failure upstream of the walk would satisfy this test
    // while proving nothing about the empty-answer case it exists for.
    assert!(
        text.contains("No assignment to"),
        "the error must be the walked-and-found-nothing answer, not an \
         unrelated failure: {text}"
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
    // Pin the reason, so an unrelated upstream failure cannot satisfy this.
    assert!(
        text.contains("was never hit"),
        "the error must say the breakpoint was not reached: {text}"
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

    // Step 9 is the `print(c)` step for this fixture — the same query
    // point `get_value_origin` reaches via its breakpoint, and the last
    // step the recorder emits (`--step 10` answers "out of range").
    //
    // It was `goto_ticks(7)` when this test landed, which is inside the
    // `a = 10 / b = a / c = b` run: the walk found `c` unassigned and
    // answered `hops=0 terminator=parameterAtRecordStart` — an answer
    // this test's `HOPS 3` assertion rejects. It has been failing on
    // `dev` since, independently of the CLI work here.
    let script = r#"
trace.goto_ticks(9)
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

// ---------------------------------------------------------------------------
// `ct trace origin --format {json,markdown,text}` — the CLI output arms.
//
// `run_trace_origin` in `main.rs` dispatches on `--format` into three
// output paths.  Two of them call `origin_renderer::render_text` /
// `render_markdown`, whose *rendering* is unit-tested in
// `src/origin_renderer.rs` against a hand-written `json!` fixture.  The
// third — `json` — has no renderer function at all; it is an inline
// `serde_json::to_string_pretty(&body)` that nothing has ever asserted
// on.
//
// What no test covered on any arm is the CLI itself: that `--format`
// selects the matching arm, and that the chain the daemon actually
// returns for a real recording renders the way the spec says.  Four
// stub tests (`test_cli_trace_origin_{json,markdown,text,...}_output`)
// held those slots while always returning early, and were deleted when
// their harness was found to be vacuous.  These replace them for real.
//
// The expected chain is the canonical one from
// `src/db-backend/tests/fixtures/origin/python/simple_trivial_chain/ANSWERS.md`:
// `c -> b -> a`, terminating at the literal `10`.
//
// Note on the rendered locations.  A hop's `sourceText` is the statement
// that *produced* the value; its `location` is where that value is
// *read* — one statement later.  So the chain queried at `print(c)`
// (`main.py:12`) renders as:
//
//     main.py:12  c = b      (c is read at the print)
//     main.py:11  b = a      (b is read at `c = b`)
//     main.py:10  a = 10     (a is read at `b = a`)
//
// The pairing, not just the set of lines, is what these tests pin: a
// renderer that dropped `sourceText` and printed `targetExpr = sourceExpr`
// instead — its documented fallback — would still emit three plausible
// rows, and would fail here.
// ---------------------------------------------------------------------------

/// The `print(c)` step in a `simple_trivial_chain` recording.
///
/// It is the last step the recorder emits for this fixture (`--step 10`
/// answers `step_id 10 is out of range`), which is what makes the
/// constant stable: the fixture's final statement *is* the query point
/// the ANSWERS.md chain is stated for.
const PRINT_C_STEP: &str = "9";

/// A recorded trace plus a live daemon, for driving the `ct trace
/// origin` *client* (as opposed to the MCP server).
struct CliOriginHarness {
    _daemon: TestDaemon,
    binary: PathBuf,
    root: PathBuf,
    trace_path: String,
}

impl CliOriginHarness {
    /// Run `ct trace origin <trace> --variable c --step 9 --format <format>`
    /// against this harness's daemon and return its stdout.
    ///
    /// `CODETRACER_TMP_PATH` is what the CLI client resolves its daemon
    /// socket from (`paths::Paths::default`), and it is the same
    /// `<root>/daemon.sock` that `start_daemon` created — so the client
    /// joins the harness daemon instead of auto-starting a stray one
    /// against the user's real socket.
    fn run_origin(&self, format: &str) -> String {
        let output = Command::new(&self.binary)
            .args([
                "trace",
                "origin",
                &self.trace_path,
                "--variable",
                "c",
                "--step",
                PRINT_C_STEP,
                "--format",
                format,
            ])
            .env("CODETRACER_TMP_PATH", &self.root)
            .stdin(Stdio::null())
            .output()
            .unwrap_or_else(|e| panic!("cannot run `ct trace origin --format {format}`: {e}"));

        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        assert!(
            output.status.success(),
            "`ct trace origin --format {format}` exited with {}\nstdout: {stdout}\nstderr: {stderr}",
            output.status
        );
        stdout
    }
}

/// Build the CLI harness for `scenario`, or return `None` after emitting
/// a `SKIPPED:` line naming precisely what was missing.
fn cli_origin_harness(scenario: &str) -> Option<CliOriginHarness> {
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

    Some(CliOriginHarness {
        _daemon: daemon,
        binary,
        root,
        trace_path: trace_dir.to_string_lossy().to_string(),
    })
}

/// Extract the string field `field` from each hop, trimmed.
fn hop_strings(hops: &[Value], field: &str) -> Vec<String> {
    hops.iter()
        .map(|h| {
            h.get(field)
                .and_then(Value::as_str)
                .map(|s| s.trim().to_string())
                .unwrap_or_else(|| format!("<missing {field}>"))
        })
        .collect()
}

/// `--format json` must emit the canonical wire chain, parseable and
/// carrying the documented keys — not a rendered report, and not an
/// abbreviation of the body.
#[test]
fn test_cli_trace_origin_json_output() {
    let Some(harness) = cli_origin_harness("simple_trivial_chain") else {
        return;
    };
    let stdout = harness.run_origin("json");

    let chain: Value = serde_json::from_str(stdout.trim()).unwrap_or_else(|e| {
        panic!("`--format json` did not emit parseable JSON ({e}); stdout was:\n{stdout}")
    });

    assert_eq!(
        chain.get("queryVariable").and_then(Value::as_str),
        Some("c"),
        "the JSON body must name the queried variable: {chain}"
    );

    let hops = chain
        .get("hops")
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("`--format json` emitted no `hops` array: {chain}"));
    assert_eq!(
        hops.len(),
        3,
        "ANSWERS.md expects c -> b -> a; got {} hops: {chain}",
        hops.len()
    );
    assert_eq!(
        hop_strings(hops, "kind"),
        vec!["trivialCopy", "trivialCopy", "literal"],
        "unexpected hop kinds in `--format json`: {chain}"
    );
    assert_eq!(
        hop_strings(hops, "sourceText"),
        vec!["c = b", "b = a", "a = 10"],
        "unexpected assigning statements in `--format json`: {chain}"
    );
    let lines: Vec<i64> = hops
        .iter()
        .map(|h| {
            h.get("location")
                .and_then(|l| l.get("line"))
                .and_then(Value::as_i64)
                .unwrap_or(-1)
        })
        .collect();
    assert_eq!(
        lines,
        vec![12, 11, 10],
        "hops must carry the fixture's read sites, newest first: {chain}"
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
    assert_eq!(
        chain.get("truncated").and_then(Value::as_bool),
        Some(false),
        "a three-hop chain under the default --max-hops 16 is not truncated: {chain}"
    );

    // `main.rs` promises pretty-printed, diffable JSON on this arm.  A
    // single-line `body.to_string()` would still parse, so parsing alone
    // cannot see a regression here.
    assert!(
        stdout.contains("\n  \"hops\""),
        "`--format json` must pretty-print (2-space indent), not emit one line; stdout was:\n{stdout}"
    );
}

/// `--format markdown` must emit the report layout: heading, terminator
/// bullets, and one table row per hop in walk order.
#[test]
fn test_cli_trace_origin_markdown_output() {
    let Some(harness) = cli_origin_harness("simple_trivial_chain") else {
        return;
    };
    let stdout = harness.run_origin("markdown");

    assert!(
        stdout.contains("### Origin chain — `c` @ step `"),
        "markdown must open with the chain heading naming `c`; stdout was:\n{stdout}"
    );
    assert!(
        stdout.contains("| # | Kind | Location | Source | Confidence |"),
        "markdown must carry the hop table header; stdout was:\n{stdout}"
    );
    assert!(
        stdout.contains("- **Hops:** 3"),
        "markdown must report three hops; stdout was:\n{stdout}"
    );
    assert!(
        stdout.contains("- **Truncated:** no"),
        "markdown must report the chain as complete; stdout was:\n{stdout}"
    );
    assert!(
        stdout.contains("- **Terminator:** `literal` — `10`"),
        "markdown must name the Literal 10 terminator; stdout was:\n{stdout}"
    );
    assert!(
        stdout.contains("- **Terminator function:** `main`"),
        "markdown must name the function the chain terminates in; stdout was:\n{stdout}"
    );

    // Each hop is a row, and the rows appear in walk order (newest
    // first).  Asserting the offsets rather than mere containment is
    // what makes a reordered or reversed chain fail here.
    let mut offsets = Vec::new();
    for row in [
        "| 0 | `trivialCopy` | `main.py:12` | `c = b` |",
        "| 1 | `trivialCopy` | `main.py:11` | `b = a` |",
        "| 2 | `literal` | `main.py:10` | `a = 10` |",
    ] {
        let at = stdout.find(row).unwrap_or_else(|| {
            panic!("markdown is missing the row `{row}`; stdout was:\n{stdout}")
        });
        offsets.push(at);
    }
    assert!(
        offsets[0] < offsets[1] && offsets[1] < offsets[2],
        "markdown hop rows must render in walk order c -> b -> a, got offsets {offsets:?}; \
         stdout was:\n{stdout}"
    );
}

/// `--format text` must emit the spec §3.2.2 ASCII layout: header,
/// summary line, one glyph-tagged hop block per hop in walk order, and
/// the terminator row last.
#[test]
fn test_cli_trace_origin_text_output_matches_spec_layout() {
    let Some(harness) = cli_origin_harness("simple_trivial_chain") else {
        return;
    };
    let stdout = harness.run_origin("text");

    assert!(
        stdout.starts_with("Origin chain for 'c' @ step="),
        "text must open with the spec header line; stdout was:\n{stdout}"
    );
    assert!(
        stdout.contains("  hops=3 terminator=literal truncated=no"),
        "text must carry the spec summary line; stdout was:\n{stdout}"
    );

    // Hop blocks: the glyph, the location, and the assigning statement
    // on the following line — in walk order.
    let mut offsets = Vec::new();
    for block in [
        "  0. [=] main.py:12\n     c = b",
        "  1. [=] main.py:11\n     b = a",
        "  2. [L] main.py:10\n     a = 10",
    ] {
        let at = stdout.find(block).unwrap_or_else(|| {
            panic!("text is missing the hop block:\n{block}\nstdout was:\n{stdout}")
        });
        offsets.push(at);
    }
    assert!(
        offsets[0] < offsets[1] && offsets[1] < offsets[2],
        "text hop blocks must render in walk order c -> b -> a, got offsets {offsets:?}; \
         stdout was:\n{stdout}"
    );

    // The terminator row closes the chain, after the last hop.
    let terminator_at = stdout.find("  [lit] 10").unwrap_or_else(|| {
        panic!("text is missing the `[lit] 10` terminator; stdout was:\n{stdout}")
    });
    assert!(
        terminator_at > offsets[2],
        "the terminator row must come after the final hop; stdout was:\n{stdout}"
    );
    // …and is annotated with the function it terminates in.
    let function_at = stdout.find("      @ main").unwrap_or_else(|| {
        panic!("text is missing the `@ main` annotation; stdout was:\n{stdout}")
    });
    assert!(
        function_at > terminator_at,
        "the function annotation belongs under the terminator; stdout was:\n{stdout}"
    );
}

/// The three arms must be three *different* renderings.
///
/// Each test above would pass if its own arm were correct while another
/// fell through to it; only comparing the arms pins the `match format`
/// in `run_trace_origin` itself.  The fall-through is not hypothetical:
/// the `_` arm is the text renderer, so a mis-spelled `"markdown"`
/// pattern would silently downgrade markdown to text.
#[test]
fn test_cli_trace_origin_formats_are_distinct() {
    let Some(harness) = cli_origin_harness("simple_trivial_chain") else {
        return;
    };
    let json = harness.run_origin("json");
    let markdown = harness.run_origin("markdown");
    let text = harness.run_origin("text");

    assert_ne!(
        json.trim(),
        text.trim(),
        "`--format json` fell through to the text arm"
    );
    assert_ne!(
        markdown.trim(),
        text.trim(),
        "`--format markdown` fell through to the text arm"
    );
    assert_ne!(
        json.trim(),
        markdown.trim(),
        "`--format json` and `--format markdown` produced identical output"
    );

    // And each is recognisably its own shape.
    assert!(
        json.trim_start().starts_with('{'),
        "the json arm must emit a JSON object: {json}"
    );
    assert!(
        markdown.starts_with("### "),
        "the markdown arm must emit a markdown heading: {markdown}"
    );
    assert!(
        text.starts_with("Origin chain for "),
        "the text arm must emit the ASCII layout: {text}"
    );
}
