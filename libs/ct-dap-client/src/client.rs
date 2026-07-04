use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use log::info;
use serde_json::{json, Value};

/// Scale factor applied to every DAP timeout in this module.
///
/// The hard-coded per-operation timeouts (10s response / 30s step) were
/// fine for tests run in isolation but proved too tight under contended
/// parallel load (`just test` runs the full suite via `cargo nextest`,
/// which spawns dozens of test binaries that race for CPU + perf counter
/// resources). Under such load, RR / LLDB / db-backend pipelines have
/// been measured to stall for tens of seconds while the flow-loader is
/// computing a single `ct/updated-flow` event for a Go fixture — a
/// previous 3x scaling (30s) still produced spurious
/// `Timeout waiting for event 'ct/updated-flow'` failures on
/// `go_flow_variables_and_values`.
///
/// The default scaling factor (6x → 60s upper bound for what used to be
/// 10s) keeps the *production-meaningful* assertions intact — the test
/// still verifies that the db-backend reaches the requested state — while
/// giving the kernel scheduler enough headroom that the deadline reflects
/// realistic worst-case variance rather than best-case latency on an
/// unloaded box. 60s is also still well below the per-test nextest
/// slow-timeout for `_flow_` tests (which is 120s, configured in
/// `.config/nextest.toml`), so a genuine production stall surfaces as a
/// real timeout rather than as silent hangs.
///
/// Operators (and the harness) can override via the
/// `CODETRACER_DAP_CLIENT_TIMEOUT_SCALE` environment variable when running
/// on slow hardware or in highly oversubscribed CI; the value is a
/// floating-point multiplier and any non-finite / non-positive value falls
/// back to the default.
fn timeout_scale() -> f64 {
    match std::env::var("CODETRACER_DAP_CLIENT_TIMEOUT_SCALE") {
        Ok(raw) => match raw.trim().parse::<f64>() {
            Ok(v) if v.is_finite() && v > 0.0 => v,
            _ => 6.0,
        },
        Err(_) => 6.0,
    }
}

/// Scale a base duration by [`timeout_scale`], saturating at
/// `Duration::MAX` to avoid arithmetic overflow on absurd scale values.
///
/// Public so that `test_support` helpers (which pass timeouts directly
/// into [`DapStdioClient::wait_for_stopped`] etc.) can apply the same
/// scaling factor as the in-crate call sites.
pub fn scaled(base: Duration) -> Duration {
    let secs = (base.as_secs_f64() * timeout_scale()).clamp(0.0, u64::MAX as f64);
    Duration::from_secs_f64(secs)
}

use crate::protocol::{DapMessage, Event, ProtocolMessage, Request, Response};
use crate::transport::{read_dap_message, write_dap_message};
use crate::types::*;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

fn validate_set_breakpoints_body(body: &Value, expected_count: usize) -> Result<(), BoxError> {
    let breakpoints = body
        .get("breakpoints")
        .and_then(Value::as_array)
        .ok_or("setBreakpoints response did not contain a breakpoints array")?;
    if breakpoints.len() != expected_count {
        return Err(format!(
            "setBreakpoints returned {} breakpoints, expected {}: {}",
            breakpoints.len(),
            expected_count,
            body
        )
        .into());
    }

    let unresolved = breakpoints
        .iter()
        .enumerate()
        .filter(|(_, bp)| bp.get("verified").and_then(Value::as_bool) != Some(true))
        .map(|(index, bp)| format!("#{index}: {bp}"))
        .collect::<Vec<_>>();
    if !unresolved.is_empty() {
        return Err(format!(
            "setBreakpoints returned unresolved breakpoints: {}",
            unresolved.join(", ")
        )
        .into());
    }

    Ok(())
}

/// A DAP client that communicates with db-backend over stdio.
pub struct DapStdioClient {
    child: Child,
    writer: ChildStdin,
    rx: Receiver<Result<DapMessage, String>>,
    _reader_thread: JoinHandle<()>,
    _stderr_thread: JoinHandle<()>,
    stderr_lines: Arc<Mutex<Vec<String>>>,
    seq: i64,
}

impl DapStdioClient {
    /// Spawn a db-backend process and set up DAP communication over stdio.
    ///
    /// db-backend (and the ct-native-replay replay-worker it spawns) reads
    /// the daily-free-tier license counter from `$XDG_DATA_HOME/codetracer/state.db`.
    /// Without isolation, every test invocation increments the developer's
    /// real `~/.local/share/codetracer/state.db`; once the daily quota is
    /// exhausted, the replay-worker exits with
    /// `daily_replay_limit_reached`, which surfaces in the DAP layer as a
    /// db-backend startup timeout. Point XDG_DATA_HOME at a per-process
    /// temp dir so each test run starts with a fresh counter.
    pub fn spawn(db_backend_bin: &Path) -> Result<Self, BoxError> {
        Self::spawn_with_envs(db_backend_bin, &[])
    }

    /// Spawn db-backend with additional environment variables.
    ///
    /// Each `(key, value)` pair is passed to the child process on top of the
    /// default isolation env vars (`XDG_DATA_HOME`, `HOME`). Used by multi-
    /// process tests to inject `CT_NATIVE_REPLAY_TARGET_PID` so the replay
    /// worker spawns `rr replay -f <pid>` / `-p <pid>` against the requested
    /// process in the recording.
    pub fn spawn_with_envs(
        db_backend_bin: &Path,
        extra_envs: &[(&str, &str)],
    ) -> Result<Self, BoxError> {
        let license_iso_dir = if cfg!(unix) {
            PathBuf::from(format!("/tmp/ctd{}", std::process::id()))
        } else {
            std::env::temp_dir().join(format!("ct_dap_license_iso_{}", std::process::id()))
        };
        let _ = std::fs::create_dir_all(&license_iso_dir);
        let mut command = Command::new(db_backend_bin);
        command
            .arg("dap-server")
            .arg("--stdio")
            .env("XDG_DATA_HOME", &license_iso_dir)
            .env("HOME", &license_iso_dir);
        for (key, value) in extra_envs {
            command.env(*key, *value);
        }
        // Put db-backend (and every process it spawns — ct-native-replay,
        // the replay-worker, debugserver/lldb) into a NEW process group whose
        // leader is db-backend itself.  Teardown then signals the whole group
        // (`killpg`) so the replay descendants are reaped together with the
        // parent.  Without this, killing only the direct child orphans the
        // replay-worker + debugserver; on macOS those orphans keep the
        // fixed-address MCR replay mappings (§6B.5) reserved and squat the
        // bootstrap socket, so the NEXT *_mcr_streaming_flow_test in a
        // sequential `cargo nextest` run fails its mmap reservation /
        // boundary handshake.  Process-group reaping is what makes
        // back-to-back flow tests reliable without a manual `pkill`.
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            // 0 ⇒ the child becomes the leader of a new group equal to its pid.
            command.process_group(0);
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| {
                format!(
                    "Failed to spawn db-backend at {}: {}",
                    db_backend_bin.display(),
                    e
                )
            })?;

        let writer = child
            .stdin
            .take()
            .ok_or("Failed to get stdin of db-backend")?;
        let stdout = child
            .stdout
            .take()
            .ok_or("Failed to get stdout of db-backend")?;
        let stderr = child
            .stderr
            .take()
            .ok_or("Failed to get stderr of db-backend")?;

        let (tx, rx) = mpsc::channel();

        let reader_thread = thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                match read_dap_message(&mut reader) {
                    Ok(msg) => {
                        if tx.send(Ok(msg)).is_err() {
                            break;
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(Err(e.to_string()));
                        break;
                    }
                }
            }
        });

        // Capture stderr for diagnostics
        let stderr_lines = Arc::new(Mutex::new(Vec::new()));
        let stderr_lines_clone = Arc::clone(&stderr_lines);
        let stderr_thread = thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines() {
                match line {
                    Ok(line) => {
                        info!("db-backend stderr: {}", line);
                        if let Ok(mut lines) = stderr_lines_clone.lock() {
                            lines.push(line);
                        }
                    }
                    Err(_) => break,
                }
            }
        });

        Ok(DapStdioClient {
            child,
            writer,
            rx,
            _reader_thread: reader_thread,
            _stderr_thread: stderr_thread,
            stderr_lines,
            seq: 1,
        })
    }

    /// Kill the db-backend process AND every replay descendant it spawned.
    ///
    /// `spawn_with_envs` made db-backend a process-group leader, so on Unix we
    /// signal the whole group (negative pid ⇒ `killpg`).  We send `SIGTERM`
    /// first (lets debugserver detach the replay child cleanly), then `SIGKILL`
    /// as a backstop, then `wait()` the direct child to reap it.  This is the
    /// load-bearing teardown that stops orphaned replay-workers from squatting
    /// the fixed MCR replay addresses between sequential flow tests.
    fn kill_process_tree(&mut self) {
        #[cfg(unix)]
        {
            let pid = self.child.id() as i32;
            // SAFETY: `pid` is db-backend's own pid (a group leader since
            // spawn); -pid targets that group via the documented kill(2)
            // negative-pid contract.  Both signals are no-ops if the group is
            // already gone, so the calls are race-safe against natural exit.
            unsafe {
                libc::killpg(pid, libc::SIGTERM);
            }
            // Brief grace period for an orderly debugserver detach, then SIGKILL
            // the whole group to guarantee no replay descendant survives.
            std::thread::sleep(Duration::from_millis(150));
            unsafe {
                libc::killpg(pid, libc::SIGKILL);
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }

    /// Disconnect and kill the db-backend process (and its replay descendants).
    pub fn disconnect(mut self) -> Result<(), BoxError> {
        // Send disconnect request, ignore errors (process may already be gone)
        let _ = self.send_request("disconnect", json!({}));
        // Give it a moment then kill the whole process group.
        std::thread::sleep(Duration::from_millis(100));
        self.kill_process_tree();
        Ok(())
    }

    // === DAP initialization sequence ===

    /// Send initialize request and return capabilities.
    pub fn initialize(&mut self) -> Result<Capabilities, BoxError> {
        self.send_request(
            "initialize",
            json!({
                "clientID": "ct-dap-client",
                "clientName": "ct-dap-client",
                "adapterID": "codetracer",
                "pathFormat": "path",
                "linesStartAt1": true,
                "columnsStartAt1": true
            }),
        )?;

        let resp = self.recv_response(scaled(Duration::from_secs(10)))?;
        if !resp.success {
            return Err(format!("initialize failed: {:?}", resp.message).into());
        }

        let caps: Capabilities = serde_json::from_value(resp.body)?;
        Ok(caps)
    }

    /// Send launch request with the given arguments.
    pub fn launch(&mut self, args: LaunchRequestArguments) -> Result<(), BoxError> {
        self.send_request("launch", serde_json::to_value(&args)?)?;
        let resp = self.recv_response(scaled(Duration::from_secs(10)))?;
        if !resp.success {
            return Err(format!("launch failed: {:?}", resp.message).into());
        }
        Ok(())
    }

    /// Send configurationDone request.
    pub fn configuration_done(&mut self) -> Result<(), BoxError> {
        self.send_request("configurationDone", json!({}))?;
        let resp = self.recv_response(scaled(Duration::from_secs(10)))?;
        if !resp.success {
            return Err(format!("configurationDone failed: {:?}", resp.message).into());
        }
        Ok(())
    }

    /// Wait for a `stopped` event (emitted after configurationDone + runToEntry).
    pub fn wait_for_stopped(&mut self, timeout: Duration) -> Result<(), BoxError> {
        let start = std::time::Instant::now();
        let deadline = start + timeout;
        let mut received_events: Vec<String> = Vec::new();

        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                let stderr = self.recent_stderr(20);
                let elapsed = start.elapsed().as_secs_f64();
                let mut msg = format!("Timeout after {:.1}s waiting for event 'stopped'", elapsed);
                if !received_events.is_empty() {
                    msg.push_str(&format!(
                        "\n  Events received while waiting: {:?}",
                        received_events
                    ));
                } else {
                    msg.push_str("\n  No events received from db-backend");
                }
                if !stderr.is_empty() {
                    msg.push_str(&format!(
                        "\n  db-backend stderr (last {} lines):\n    {}",
                        stderr.len(),
                        stderr.join("\n    ")
                    ));
                }
                // Check if db-backend process is still alive
                if let Some(status) = self.child.try_wait().ok().flatten() {
                    msg.push_str(&format!("\n  db-backend process EXITED with: {}", status));
                } else {
                    msg.push_str("\n  db-backend process is still running");
                }
                return Err(msg.into());
            }
            match self.rx.recv_timeout(remaining) {
                Ok(Ok(DapMessage::Event(e))) => {
                    if e.event == "stopped" {
                        return Ok(());
                    }
                    eprintln!(
                        "[wait_for_stopped] received event '{}' at {:.1}s",
                        e.event,
                        start.elapsed().as_secs_f64()
                    );
                    received_events.push(e.event);
                }
                Ok(Ok(DapMessage::Response(r))) => {
                    if !r.success {
                        let stderr = self.recent_stderr(20);
                        let mut msg = format!(
                            "Received failed response while waiting for 'stopped': command={} request_seq={} message={:?}",
                            r.command, r.request_seq, r.message
                        );
                        if !stderr.is_empty() {
                            msg.push_str(&format!(
                                "\n  db-backend stderr (last {} lines):\n    {}",
                                stderr.len(),
                                stderr.join("\n    ")
                            ));
                        }
                        return Err(msg.into());
                    }
                    received_events.push(format!(
                        "response(seq={}, cmd={})",
                        r.request_seq, r.command
                    ));
                }
                Ok(Ok(other)) => {
                    received_events.push(format!("{:?}", other));
                }
                Ok(Err(e)) => {
                    return Err(format!(
                        "Reader error while waiting for 'stopped': {}\n  elapsed: {:.1}s\n  events so far: {:?}",
                        e,
                        start.elapsed().as_secs_f64(),
                        received_events
                    ).into());
                }
                Err(_) => {
                    // recv_timeout expired, loop will check deadline
                }
            }
        }
    }

    // === Breakpoints ===

    /// Set breakpoints in a source file. Returns the response body.
    pub fn set_breakpoints(&mut self, file: &str, lines: &[usize]) -> Result<Value, BoxError> {
        let breakpoints: Vec<_> = lines.iter().map(|l| json!({"line": l})).collect();
        self.send_request(
            "setBreakpoints",
            json!({
                "source": { "path": file },
                "breakpoints": breakpoints,
            }),
        )?;
        let resp = self.recv_response(scaled(Duration::from_secs(10)))?;
        if !resp.success {
            return Err(format!("setBreakpoints failed: {:?}", resp.message).into());
        }
        validate_set_breakpoints_body(&resp.body, lines.len())?;
        Ok(resp.body)
    }

    // === DAP continue ===

    /// Send standard DAP "continue", wait for stopped + ct/complete-move,
    /// then consume the trailing response.
    ///
    /// Returns the MoveState from ct/complete-move.
    ///
    /// db-backend's step handler sends events first (stopped,
    /// ct/complete-move) and then a response.  We must consume all three
    /// so later `recv_response` calls don't pick up a stale response
    /// belonging to this `continue` request.
    pub fn dap_continue(&mut self) -> Result<MoveState, BoxError> {
        self.dap_continue_with_timeout(scaled(Duration::from_secs(10)))
    }

    pub fn dap_continue_with_timeout(&mut self, timeout: Duration) -> Result<MoveState, BoxError> {
        self.send_request("continue", json!({"threadId": 1}))?;
        self.wait_for_stopped(timeout)?;
        let event = self.recv_event("ct/complete-move", timeout)?;
        let state: MoveState = serde_json::from_value(event.body)?;
        // Consume the trailing response sent by the step handler
        // (body is typically `0`).  Ignore errors — the response may
        // have been consumed by recv_event's skip logic if it arrived
        // before the events.
        let _ = self.recv_response(scaled(Duration::from_secs(5)));
        Ok(state)
    }

    // === Flow ===

    /// Load flow data. Sends ct/load-flow, waits for ct/updated-flow event.
    /// Returns the raw event body (caller parses as needed).
    pub fn load_flow(&mut self, args: LoadFlowArguments) -> Result<Value, BoxError> {
        self.send_request("ct/load-flow", serde_json::to_value(&args)?)?;
        // TTD flow computation in CDB mode spawns a new CDB process per
        // operation (step, load_location, load_value), so the flow loop
        // for even a small function can take several minutes.
        let event = self.recv_event("ct/updated-flow", scaled(Duration::from_secs(10)))?;
        Ok(event.body)
    }

    /// Load locals at the current stop using CodeTracer's DAP extension.
    pub fn load_locals(&mut self) -> Result<Value, BoxError> {
        self.send_request(
            "ct/load-locals",
            json!({
                "rrTicks": 0,
                "countBudget": 1000,
                "minCountLimit": 0,
                "lang": 0,
                "watchExpressions": [],
                "depthLimit": -1,
            }),
        )?;
        let resp = self.recv_response(scaled(Duration::from_secs(10)))?;
        if !resp.success {
            return Err(format!("ct/load-locals failed: {:?}", resp.message).into());
        }
        Ok(resp.body)
    }

    // === Tracepoints ===

    /// Run tracepoints and collect results.
    ///
    /// Sends `ct/run-tracepoints`, then waits for a `ct/tracepoint-results`
    /// event carrying the aggregate results. Note: this request does not
    /// produce a DAP response — only events (trace updates + results).
    pub fn run_tracepoints(
        &mut self,
        args: RunTracepointsArg,
    ) -> Result<TracepointResultsAggregate, BoxError> {
        self.send_request("ct/run-tracepoints", serde_json::to_value(&args)?)?;

        // Wait for the aggregate results event (skips intermediate trace update events)
        let event = self.recv_event("ct/tracepoint-results", scaled(Duration::from_secs(10)))?;
        let results: TracepointResultsAggregate = serde_json::from_value(event.body)?;
        Ok(results)
    }

    // === Terminal output ===

    /// Load terminal output.
    pub fn load_terminal(&mut self) -> Result<Vec<ProgramEvent>, BoxError> {
        self.send_request("ct/load-terminal", json!({}))?;
        let event = self.recv_event("ct/loaded-terminal", scaled(Duration::from_secs(10)))?;
        let events: Vec<ProgramEvent> = serde_json::from_value(event.body)?;
        Ok(events)
    }

    // === Call stack ===

    /// Request the current call stack (standard DAP stackTrace).
    ///
    /// Returns a `StackTraceResult` containing the stack frames and the
    /// total frame count as reported by the server.
    pub fn stack_trace(&mut self) -> Result<StackTraceResult, BoxError> {
        self.send_request(
            "stackTrace",
            json!({
                "threadId": 1,
            }),
        )?;
        let resp = self.recv_response(scaled(Duration::from_secs(10)))?;
        if !resp.success {
            return Err(format!("stackTrace failed: {:?}", resp.message).into());
        }
        let result: StackTraceResult = serde_json::from_value(resp.body)?;
        Ok(result)
    }

    /// Request the DAP scopes for a stack frame.
    pub fn scopes(&mut self, frame_id: i64) -> Result<Value, BoxError> {
        self.send_request("scopes", json!({ "frameId": frame_id }))?;
        let resp = self.recv_response(scaled(Duration::from_secs(10)))?;
        if !resp.success {
            return Err(format!("scopes failed: {:?}", resp.message).into());
        }
        Ok(resp.body)
    }

    /// Request the DAP variables for a variables reference.
    pub fn variables(&mut self, variables_reference: i64) -> Result<Value, BoxError> {
        self.send_request(
            "variables",
            json!({ "variablesReference": variables_reference }),
        )?;
        let resp = self.recv_response(scaled(Duration::from_secs(10)))?;
        if !resp.success {
            return Err(format!("variables failed: {:?}", resp.message).into());
        }
        Ok(resp.body)
    }

    // === Navigation ===

    /// Step in (forward) using the custom ct/step protocol.
    pub fn step_in(&mut self, args: StepArg) -> Result<MoveState, BoxError> {
        self.send_step("ct/step", args)
    }

    /// Step over (forward) using the custom ct/step protocol.
    pub fn step_over(&mut self, args: StepArg) -> Result<MoveState, BoxError> {
        let mut step_args = args;
        step_args.action = Action::Next;
        self.send_step("ct/step", step_args)
    }

    /// Continue forward using the custom ct/step protocol.
    pub fn continue_forward(&mut self, args: StepArg) -> Result<MoveState, BoxError> {
        let mut step_args = args;
        step_args.action = Action::Continue;
        self.send_step("ct/step", step_args)
    }

    /// Step in backward (reverse step).
    pub fn step_back(&mut self) -> Result<MoveState, BoxError> {
        self.send_step("ct/step", StepArg::new(Action::StepIn, true))
    }

    /// Continue backward (reverse continue).
    pub fn continue_back(&mut self) -> Result<MoveState, BoxError> {
        self.send_step("ct/step", StepArg::new(Action::Continue, true))
    }

    fn send_step(&mut self, command: &str, args: StepArg) -> Result<MoveState, BoxError> {
        self.send_request(command, serde_json::to_value(&args)?)?;
        let event = self.recv_event("ct/complete-move", scaled(Duration::from_secs(30)))?;
        let state: MoveState = serde_json::from_value(event.body)?;
        Ok(state)
    }

    /// Send a standard DAP step command (`next`, `stepIn`, `stepOut`)
    /// and wait for the stopped + ct/complete-move events, then consume
    /// the trailing response.
    ///
    /// Unlike `step_in`/`step_over` (which use the custom `ct/step`
    /// protocol for socket-based connections), this method uses the
    /// standard DAP command names that the stdio-based server expects.
    pub fn dap_step(&mut self, command: &str) -> Result<MoveState, BoxError> {
        self.dap_step_with_timeout(command, scaled(Duration::from_secs(10)))
    }

    pub fn dap_step_with_timeout(&mut self, command: &str, timeout: Duration) -> Result<MoveState, BoxError> {
        self.send_request(command, json!({"threadId": 1}))?;
        self.wait_for_stopped(timeout)?;
        let event = self.recv_event("ct/complete-move", timeout)?;
        let state: MoveState = serde_json::from_value(event.body)?;
        // Consume the trailing response sent by the step handler.
        let _ = self.recv_response(scaled(Duration::from_secs(5)));
        Ok(state)
    }

    /// Send standard DAP `reverseContinue` over stdio and return the
    /// CodeTracer move state from the matching `ct/complete-move` event.
    pub fn dap_reverse_continue(&mut self) -> Result<MoveState, BoxError> {
        self.dap_step("reverseContinue")
    }

    pub fn dap_reverse_continue_with_timeout(&mut self, timeout: Duration) -> Result<MoveState, BoxError> {
        self.dap_step_with_timeout("reverseContinue", timeout)
    }

    /// Send standard DAP `stepBack` over stdio and return the CodeTracer
    /// move state from the matching `ct/complete-move` event.
    pub fn dap_step_back(&mut self) -> Result<MoveState, BoxError> {
        self.dap_step("stepBack")
    }

    // === Low-level send/receive ===

    /// Send a DAP request with the given command and arguments.
    pub fn send_request(&mut self, command: &str, arguments: Value) -> Result<i64, BoxError> {
        let seq = self.next_seq();
        let msg = DapMessage::Request(Request {
            base: ProtocolMessage {
                seq,
                type_: "request".to_string(),
            },
            command: command.to_string(),
            arguments,
        });
        write_dap_message(&mut self.writer, &msg)?;
        info!("DAP -> {} (seq={})", command, seq);
        Ok(seq)
    }

    /// Receive the next response, skipping events.
    pub fn recv_response(&mut self, timeout: Duration) -> Result<Response, BoxError> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return Err("Timeout waiting for response".into());
            }
            match self.rx.recv_timeout(remaining) {
                Ok(Ok(DapMessage::Response(r))) => return Ok(r),
                Ok(Ok(DapMessage::Event(e))) => {
                    info!("DAP <- event: {} (while waiting for response)", e.event);
                    continue;
                }
                Ok(Ok(other)) => {
                    info!(
                        "DAP <- unexpected message while waiting for response: {:?}",
                        other
                    );
                    continue;
                }
                Ok(Err(e)) => return Err(format!("Reader error: {}", e).into()),
                Err(_) => return Err("Timeout waiting for response".into()),
            }
        }
    }

    /// Receive a specific named event, skipping other messages.
    pub fn recv_event(&mut self, event_name: &str, timeout: Duration) -> Result<Event, BoxError> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return Err(format!("Timeout waiting for event '{}'", event_name).into());
            }
            match self.rx.recv_timeout(remaining) {
                Ok(Ok(DapMessage::Event(e))) => {
                    if e.event == event_name {
                        return Ok(e);
                    }
                    info!("DAP <- event: {} (waiting for {})", e.event, event_name);
                    continue;
                }
                Ok(Ok(DapMessage::Response(r))) => {
                    info!(
                        "DAP <- response (seq={}) while waiting for event '{}'",
                        r.request_seq, event_name
                    );
                    continue;
                }
                Ok(Ok(other)) => {
                    info!(
                        "DAP <- unexpected message while waiting for event '{}': {:?}",
                        event_name, other
                    );
                    continue;
                }
                Ok(Err(e)) => return Err(format!("Reader error: {}", e).into()),
                Err(_) => return Err(format!("Timeout waiting for event '{}'", event_name).into()),
            }
        }
    }

    /// Receive the next message of any type.
    pub fn recv_message(&mut self, timeout: Duration) -> Result<DapMessage, BoxError> {
        match self.rx.recv_timeout(timeout) {
            Ok(Ok(msg)) => Ok(msg),
            Ok(Err(e)) => Err(format!("Reader error: {}", e).into()),
            Err(_) => Err("Timeout waiting for message".into()),
        }
    }

    /// Get recent stderr output from db-backend (last N lines).
    pub fn recent_stderr(&self, max_lines: usize) -> Vec<String> {
        if let Ok(lines) = self.stderr_lines.lock() {
            let start = lines.len().saturating_sub(max_lines);
            lines[start..].to_vec()
        } else {
            vec![]
        }
    }

    fn next_seq(&mut self) -> i64 {
        let current = self.seq;
        self.seq += 1;
        current
    }
}

impl Drop for DapStdioClient {
    /// Safety net for the `disconnect()`/`finish()` teardown.
    ///
    /// Tests normally call `FlowTestRunner::finish()` (→ `disconnect()`) which
    /// reaps the process group explicitly.  But a test that panics mid-flow
    /// (e.g. an `expect(...)` on a flow assertion) unwinds WITHOUT calling
    /// `finish`, so the only thing that runs is this `Drop`.  Reaping the whole
    /// process group here is what keeps a FAILED `*_mcr_streaming_flow_test`
    /// from leaking a replay-worker/debugserver that squats the fixed replay
    /// addresses and breaks the NEXT test in a sequential `cargo nextest` run.
    fn drop(&mut self) {
        self.kill_process_tree();
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::validate_set_breakpoints_body;

    #[test]
    fn validates_verified_set_breakpoints_response() {
        let body = json!({
            "breakpoints": [
                { "verified": true, "line": 9, "id": 1 },
                { "verified": true, "line": 13, "id": 2 }
            ]
        });

        validate_set_breakpoints_body(&body, 2).expect("verified breakpoints should pass");
    }

    #[test]
    fn rejects_unresolved_set_breakpoints_response() {
        let body = json!({
            "breakpoints": [
                { "verified": true, "line": 9, "id": 1 },
                { "verified": false, "line": 13, "message": "no resolved locations" }
            ]
        });

        let err = validate_set_breakpoints_body(&body, 2)
            .expect_err("unresolved breakpoints should fail");
        assert!(
            err.to_string().contains("unresolved breakpoints"),
            "unexpected error: {err}"
        );
    }
}
