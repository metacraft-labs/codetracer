//! Class-closing check for the MCP tool surface.
//!
//! The defect this guards against: `tools/list` advertising a tool that
//! `tools/call` does not dispatch, so a client that believes the server's
//! own advertisement gets `-32602 Unknown tool: <name>`.  That happened
//! for `get_value_origin` and `resolve_variable_step` — advertised since
//! the M8 milestone, never wired into `handle_tools_call`.
//!
//! The permanent fix is structural: `mcp_server::TOOLS` is a single table
//! whose entries carry BOTH a schema and a dispatch function, so an
//! advertised-but-undispatched tool cannot be expressed.  This test is
//! the behavioural backstop for that invariant — it needs no per-tool
//! maintenance, because it derives the tool list from the server itself.
//!
//! It deliberately drives the real `trace mcp` subprocess over stdio, so
//! it exercises the actual JSON-RPC dispatch rather than any in-process
//! helper.  No daemon is required: every tool validates its required
//! arguments before touching the daemon socket, so calling each tool with
//! `{}` exercises dispatch and stops short of any I/O.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

use serde_json::{Value, json};

/// Locate the built `session-manager` / `backend-manager` binary next to
/// this test binary inside `target/<profile>/`.
fn find_binary() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let mut p = exe;
    for _ in 0..4 {
        p.pop();
        for name in ["session-manager", "backend-manager"] {
            let candidate = p.join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

struct McpStdio {
    child: Child,
    stdin: std::process::ChildStdin,
    reader: BufReader<std::process::ChildStdout>,
    next_id: i64,
}

impl McpStdio {
    fn spawn(binary: &Path) -> McpStdio {
        let mut child = Command::new(binary)
            .args(["trace", "mcp"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            // Point the daemon socket at a path that cannot exist, so a
            // handler that *did* reach the daemon fails fast instead of
            // auto-starting a real one.
            .env("CODETRACER_DAEMON_SOCK", "/nonexistent/mcp-tool-surface.sock")
            .spawn()
            .expect("failed to spawn `trace mcp`");
        let stdin = child.stdin.take().expect("no stdin");
        let stdout = child.stdout.take().expect("no stdout");
        let mut c = McpStdio {
            child,
            stdin,
            reader: BufReader::new(stdout),
            next_id: 1,
        };
        let init = c.request("initialize", json!({}));
        assert!(
            init.get("result").is_some(),
            "initialize must succeed: {init}"
        );
        c
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        let msg = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.stdin, "{msg}").expect("write to MCP stdin");
        self.stdin.flush().expect("flush MCP stdin");
        loop {
            let mut line = String::new();
            let n = self.reader.read_line(&mut line).expect("read MCP stdout");
            assert!(n > 0, "MCP subprocess closed stdout while awaiting {method}");
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let value: Value =
                serde_json::from_str(trimmed).unwrap_or_else(|e| panic!("bad JSON {trimmed}: {e}"));
            if value.get("id").and_then(Value::as_i64) == Some(id) {
                return value;
            }
        }
    }
}

impl Drop for McpStdio {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Every tool the server advertises through `tools/list` must be
/// dispatched by `tools/call`.
///
/// A tool that is advertised but not dispatched answers `-32602 Unknown
/// tool: <name>` — the client asked for exactly what it was told exists.
/// This is the check that must stay green; it derives its expectations
/// from the server, so a newly added tool is covered automatically.
#[test]
fn every_advertised_tool_is_dispatched() {
    let binary = find_binary().expect(
        "backend-manager binary not built; run `cargo build --tests` in src/backend-manager",
    );
    let mut mcp = McpStdio::spawn(&binary);

    let listed = mcp.request("tools/list", json!({}));
    let tools = listed
        .get("result")
        .and_then(|r| r.get("tools"))
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("tools/list returned no tools array: {listed}"))
        .clone();

    // Population count: a silently empty list would make every assertion
    // below vacuous.
    assert!(
        tools.len() >= 8,
        "tools/list advertised only {} tools — the surface shrank unexpectedly: {listed}",
        tools.len()
    );

    let mut undispatched: Vec<String> = Vec::new();
    for tool in &tools {
        let name = tool
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_else(|| panic!("advertised tool without a name: {tool}"))
            .to_string();

        let response = mcp.request("tools/call", json!({"name": name, "arguments": {}}));

        // A dispatched tool answers with a `result` (usually a
        // `Missing required argument` tool error, which is fine — the
        // point is that dispatch happened).  An UNdispatched tool
        // answers with the JSON-RPC error -32602 "Unknown tool: <name>".
        if let Some(error) = response.get("error") {
            let code = error.get("code").and_then(Value::as_i64).unwrap_or(0);
            let message = error.get("message").and_then(Value::as_str).unwrap_or("");
            if code == -32602 && message.starts_with("Unknown tool") {
                undispatched.push(name.clone());
                continue;
            }
            panic!("tools/call for advertised tool {name:?} failed unexpectedly: {response}");
        }
    }

    assert!(
        undispatched.is_empty(),
        "these tools are advertised by tools/list but not dispatched by tools/call, \
         so any client that trusts the advertisement gets `-32602 Unknown tool`: {undispatched:?}"
    );
}

/// The inverse direction: a name the server does NOT advertise must be
/// rejected with `-32602`.  Without this, "every advertised tool is
/// dispatched" could be satisfied by a catch-all arm that pretends to
/// handle anything.
#[test]
fn unadvertised_tool_names_are_rejected() {
    let binary = find_binary().expect(
        "backend-manager binary not built; run `cargo build --tests` in src/backend-manager",
    );
    let mut mcp = McpStdio::spawn(&binary);

    let response = mcp.request(
        "tools/call",
        json!({"name": "definitely_not_a_codetracer_tool", "arguments": {}}),
    );
    let error = response
        .get("error")
        .unwrap_or_else(|| panic!("unknown tool must produce a JSON-RPC error: {response}"));
    assert_eq!(
        error.get("code").and_then(Value::as_i64),
        Some(-32602),
        "unknown tool must answer -32602: {response}"
    );
}
