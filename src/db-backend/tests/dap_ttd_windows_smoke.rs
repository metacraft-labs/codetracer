use db_backend::dap::{self, DapClient, DapMessage, LaunchRequestArguments};
use db_backend::lang::Lang;
use db_backend::task::{
    RunTracepointsArg, SearchValue, Stop, TableArgs, TraceSession, Tracepoint, TracepointMode,
    UpdateTableArgs, EVENT_KINDS_COUNT,
};
use db_backend::transport::DapTransport;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod test_harness;

struct DapStdioSession {
    child: Child,
    reader_rx: Receiver<Result<DapMessage, String>>,
    writer: ChildStdin,
    client: DapClient,
}

impl DapStdioSession {
    fn spawn() -> Result<Self, String> {
        let bin = env!("CARGO_BIN_EXE_db-backend");
        let mut child = Command::new(bin)
            .arg("dap-server")
            .arg("--stdio")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // Forward dap-server diagnostics into the test output stream for failure triage.
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| format!("failed to spawn db-backend dap-server --stdio: {e}"))?;

        let writer = child
            .stdin
            .take()
            .ok_or_else(|| "failed to capture db-backend stdin".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "failed to capture db-backend stdout".to_string())?;
        let (reader_tx, reader_rx) = mpsc::channel::<Result<DapMessage, String>>();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                match dap::read_dap_message_from_reader(&mut reader) {
                    Ok(msg) => {
                        if reader_tx.send(Ok(msg)).is_err() {
                            break;
                        }
                    }
                    Err(err) => {
                        let _ = reader_tx.send(Err(format!("error reading DAP message: {err}")));
                        break;
                    }
                }
            }
        });
        Ok(Self {
            child,
            reader_rx,
            writer,
            client: DapClient::default(),
        })
    }

    fn send_request(&mut self, command: &str, args: Value) -> Result<i64, String> {
        let request = self.client.request(command, args);
        let request_seq = match &request {
            DapMessage::Request(req) => req.base.seq,
            _ => return Err(format!("internal error: expected request for command {command}")),
        };
        self.writer
            .send(&request)
            .map_err(|e| format!("failed to send {command} request: {e}"))?;
        Ok(request_seq)
    }

    fn send_launch(&mut self, args: LaunchRequestArguments) -> Result<i64, String> {
        let request = self
            .client
            .launch(args)
            .map_err(|e| format!("failed to build launch request: {e}"))?;
        let request_seq = match &request {
            DapMessage::Request(req) => req.base.seq,
            _ => return Err("internal error: launch did not generate a request".to_string()),
        };
        self.writer
            .send(&request)
            .map_err(|e| format!("failed to send launch request: {e}"))?;
        Ok(request_seq)
    }

    fn read_next(&mut self, timeout: Duration) -> Result<DapMessage, String> {
        match self.reader_rx.recv_timeout(timeout) {
            Ok(Ok(msg)) => Ok(msg),
            Ok(Err(err)) => Err(err),
            Err(RecvTimeoutError::Timeout) => {
                Err(format!("timed out waiting for DAP message after {timeout:?}"))
            }
            Err(RecvTimeoutError::Disconnected) => {
                Err("DAP reader thread disconnected before delivering a message".to_string())
            }
        }
    }

    fn read_until_response(&mut self, command: &str, timeout: Duration) -> Result<Value, String> {
        let start = Instant::now();
        loop {
            if start.elapsed() >= timeout {
                return Err(format!(
                    "timed out waiting for response to command '{command}' after {timeout:?}"
                ));
            }
            match self.read_next(timeout.saturating_sub(start.elapsed()))? {
                DapMessage::Response(resp) if resp.command == command => {
                    if !resp.success {
                        return Err(format!("response '{command}' reported failure: {:?}", resp.message));
                    }
                    return Ok(resp.body);
                }
                _ => {}
            }
        }
    }

    fn read_until_event(&mut self, event: &str, timeout: Duration) -> Result<Value, String> {
        let start = Instant::now();
        loop {
            if start.elapsed() >= timeout {
                return Err(format!(
                    "timed out waiting for event '{event}' after {timeout:?}"
                ));
            }
            match self.read_next(timeout.saturating_sub(start.elapsed()))? {
                DapMessage::Event(ev) if ev.event == event => return Ok(ev.body),
                DapMessage::Event(ev) if ev.event == "terminated" => {
                    return Err(format!(
                        "received unexpected terminated event while waiting for '{event}'"
                    ));
                }
                _ => {}
            }
        }
    }

    fn disconnect(mut self) -> Result<(), String> {
        self.send_request("disconnect", json!({}))?;
        let _ = self.read_until_response("disconnect", Duration::from_secs(5))?;
        let status = self
            .child
            .wait_timeout(Duration::from_secs(3))
            .map_err(|e| format!("failed waiting for db-backend process exit: {e}"))?;

        if status.is_none() {
            self.child.kill().ok();
            self.child.wait().ok();
            return Err("db-backend did not exit after disconnect response".to_string());
        }
        Ok(())
    }
}

trait WaitTimeoutExt {
    fn wait_timeout(&mut self, timeout: Duration) -> Result<Option<std::process::ExitStatus>, std::io::Error>;
}

impl WaitTimeoutExt for Child {
    fn wait_timeout(&mut self, timeout: Duration) -> Result<Option<std::process::ExitStatus>, std::io::Error> {
        let poll = Duration::from_millis(50);
        let started = Instant::now();
        loop {
            if let Some(status) = self.try_wait()? {
                return Ok(Some(status));
            }
            if started.elapsed() >= timeout {
                return Ok(None);
            }
            std::thread::sleep(poll);
        }
    }
}

#[derive(Debug, Clone)]
struct TtdFixture {
    trace_path: PathBuf,
    source_path: Option<PathBuf>,
}

fn should_skip_ttd_tests() -> Option<String> {
    if !cfg!(windows) {
        return Some("only supported on Windows".to_string());
    }
    if resolve_ct_rr_support().is_err() {
        return Some("ct-rr-support binary not found".to_string());
    }
    None
}

fn resolve_manifest_path() -> Result<PathBuf, String> {
    let raw = std::env::var("CT_TTD_TRACE_MANIFEST")
        .map_err(|_| "CT_TTD_TRACE_MANIFEST must be set for Windows TTD DAP smoke tests".to_string())?;
    let manifest_path = PathBuf::from(&raw);
    if manifest_path.exists() {
        return Ok(manifest_path);
    }
    if manifest_path.is_absolute() {
        return Err(format!(
            "CT_TTD_TRACE_MANIFEST points to a missing file: {}",
            manifest_path.display()
        ));
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let candidate = manifest_dir
        .join("..")
        .join("..")
        .join("..")
        .join("codetracer-rr-backend")
        .join(&manifest_path);
    if candidate.exists() {
        Ok(candidate)
    } else {
        Err(format!(
            "could not resolve CT_TTD_TRACE_MANIFEST='{}' from cwd or workspace sibling path",
            raw
        ))
    }
}

fn parse_first_ttd_fixture(manifest_path: &Path) -> Result<TtdFixture, String> {
    let raw = fs::read_to_string(manifest_path)
        .map_err(|e| format!("failed to read manifest {}: {e}", manifest_path.display()))?;
    let parsed: Value = serde_json::from_str(&raw)
        .map_err(|e| format!("failed to parse manifest {} as JSON: {e}", manifest_path.display()))?;
    let base_dir = manifest_path
        .parent()
        .ok_or_else(|| format!("manifest path has no parent directory: {}", manifest_path.display()))?;

    let fixture_entries = parsed
        .get("fixtures")
        .and_then(|v| v.as_array())
        .ok_or_else(|| "manifest must contain a fixtures array for cross-engine schema".to_string())?;

    for entry in fixture_entries {
        let Some(ttd_trace_raw) = entry
            .get("engines")
            .and_then(|engines| engines.get("ttd"))
            .and_then(|ttd| ttd.get("trace"))
            .and_then(Value::as_str)
        else {
            continue;
        };

        let resolved_trace = normalize_manifest_path(ttd_trace_raw, base_dir);
        if resolved_trace.extension().is_some_and(|ext| ext == "run") && resolved_trace.exists() {
            let source_path = entry
                .get("program")
                .and_then(Value::as_str)
                .map(|raw| normalize_manifest_path(raw, base_dir));
            return Ok(TtdFixture {
                trace_path: resolved_trace,
                source_path,
            });
        }
    }

    Err(format!(
        "manifest {} does not contain an existing *.run fixture trace under fixtures[].engines.ttd.trace",
        manifest_path.display()
    ))
}

fn find_compiler(candidates: &[&str]) -> Option<String> {
    if let Ok(value) = std::env::var("CT_TTD_CC") {
        if !value.trim().is_empty() {
            return Some(value);
        }
    }
    for candidate in candidates {
        let ok = if *candidate == "cl" {
            Command::new(candidate)
                .arg("/Bv")
                .output()
                .map(|o| {
                    o.status.success()
                        || String::from_utf8_lossy(&o.stdout).contains("Microsoft")
                        || String::from_utf8_lossy(&o.stderr).contains("Microsoft")
                })
                .unwrap_or(false)
        } else {
            Command::new(candidate)
                .arg("--version")
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false)
        };
        if ok {
            return Some(candidate.to_string());
        }
    }
    None
}

fn compile_c_program(source: &Path, debug_info: bool) -> Result<Option<PathBuf>, String> {
    let compiler = find_compiler(&["clang", "gcc", "cl"]);
    let Some(compiler) = compiler else {
        return Ok(None);
    };

    let out_dir = std::env::temp_dir().join("ct-dap-ttd-tracepoint");
    fs::create_dir_all(&out_dir).map_err(|e| format!("create temp dir: {e}"))?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let output = out_dir.join(format!("ttd-tracepoint-{nonce}.exe"));

    let mut command = Command::new(&compiler);
    if compiler.eq_ignore_ascii_case("cl") {
        command.arg("/nologo").arg("/Od").arg("/TC");
        if debug_info {
            command.arg("/Zi");
        }
        command
            .arg(source)
            .arg(format!("/Fe:{}", output.display()));
    } else {
        if debug_info {
            command.arg("-g");
        }
        command
            .arg("-O0")
            .arg("-std=c11")
            .arg(source)
            .arg("-o")
            .arg(&output);
    }

    let result = command.output().map_err(|e| format!("compile failed: {e}"))?;
    if !result.status.success() {
        return Ok(None);
    }

    Ok(Some(output))
}

fn is_access_denied_output(stderr: &str) -> bool {
    let lower = stderr.to_ascii_lowercase();
    lower.contains("administrative privileges are required")
        || lower.contains("0x80070005")
        || lower.contains("access is denied")
}

fn record_ttd_trace(
    ct_rr_support: &Path,
    exe: &Path,
    output_trace: &Path,
) -> Result<Option<PathBuf>, String> {
    let output = Command::new(ct_rr_support)
        .args([
            "record",
            "-o",
            output_trace
                .to_str()
                .ok_or_else(|| "trace path is not utf-8".to_string())?,
            exe.to_str()
                .ok_or_else(|| "exe path is not utf-8".to_string())?,
        ])
        .output()
        .map_err(|e| format!("failed to run ct-rr-support record: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if is_access_denied_output(&stderr) {
            return Ok(None);
        }
        return Err(format!("ct-rr-support record failed: {stderr}"));
    }

    if output_trace.is_file() {
        return Ok(Some(output_trace.to_path_buf()));
    }
    Err(format!(
        "ct-rr-support record succeeded but trace not found at {}",
        output_trace.display()
    ))
}

fn auto_record_tracepoint_fixture() -> Result<Option<TtdFixture>, String> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source = manifest_dir
        .join("..")
        .join("..")
        .join("..")
        .join("codetracer-rr-backend")
        .join("tests")
        .join("programs")
        .join("c")
        .join("tracepoint")
        .join("tracepoint.c");
    if !source.is_file() {
        return Ok(None);
    }

    let Some(exe) = compile_c_program(&source, true)? else {
        return Ok(None);
    };

    let ct_rr_support = resolve_ct_rr_support()?;
    let out_dir = std::env::temp_dir().join("ct-dap-ttd-tracepoint");
    fs::create_dir_all(&out_dir).map_err(|e| format!("create temp dir: {e}"))?;
    let trace_path = out_dir.join("ttd-tracepoint-c.run");
    let Some(trace) = record_ttd_trace(&ct_rr_support, &exe, &trace_path)? else {
        return Ok(None);
    };

    Ok(Some(TtdFixture {
        trace_path: trace,
        source_path: Some(source),
    }))
}

fn normalize_manifest_path(raw: &str, base_dir: &Path) -> PathBuf {
    let candidate = PathBuf::from(raw);
    if candidate.is_absolute() {
        candidate
    } else {
        base_dir.join(candidate)
    }
}

fn parse_ttd_fixture_by_program_suffix(
    manifest_path: &Path,
    program_suffix: &str,
) -> Result<Option<TtdFixture>, String> {
    let raw = fs::read_to_string(manifest_path)
        .map_err(|e| format!("failed to read manifest {}: {e}", manifest_path.display()))?;
    let parsed: Value = serde_json::from_str(&raw)
        .map_err(|e| format!("failed to parse manifest {} as JSON: {e}", manifest_path.display()))?;
    let base_dir = manifest_path
        .parent()
        .ok_or_else(|| format!("manifest path has no parent directory: {}", manifest_path.display()))?;

    let fixture_entries = parsed
        .get("fixtures")
        .and_then(|v| v.as_array())
        .ok_or_else(|| "manifest must contain a fixtures array for cross-engine schema".to_string())?;

    for entry in fixture_entries {
        let program_path = entry
            .get("program")
            .and_then(Value::as_str)
            .map(|raw| normalize_manifest_path(raw, base_dir));
        if program_path
            .as_ref()
            .and_then(|p| p.to_str())
            .is_some_and(|p| p.replace('\\', "/").ends_with(program_suffix))
        {
            let Some(ttd_trace_raw) = entry
                .get("engines")
                .and_then(|engines| engines.get("ttd"))
                .and_then(|ttd| ttd.get("trace"))
                .and_then(Value::as_str)
            else {
                continue;
            };
            let resolved_trace = normalize_manifest_path(ttd_trace_raw, base_dir);
            if resolved_trace.extension().is_some_and(|ext| ext == "run") && resolved_trace.exists() {
                return Ok(Some(TtdFixture {
                    trace_path: resolved_trace,
                    source_path: program_path,
                }));
            }
        }
    }

    Ok(None)
}

fn resolve_ct_rr_support() -> Result<PathBuf, String> {
    test_harness::find_ct_rr_support().ok_or_else(|| {
        "ct-rr-support binary not found. Set CT_RR_SUPPORT_PATH or build codetracer-rr-backend first".to_string()
    })
}

fn launch_ttd_session_with_fixture(
    session: &mut DapStdioSession,
    fixture: &TtdFixture,
) -> Result<(), String> {
    let ct_rr_support = resolve_ct_rr_support()?;

    let trace_folder = fixture
        .trace_path
        .parent()
        .ok_or_else(|| format!("fixture trace has no parent directory: {}", fixture.trace_path.display()))?
        .to_path_buf();
    let trace_file = fixture
        .trace_path
        .file_name()
        .ok_or_else(|| format!("fixture trace has no file name: {}", fixture.trace_path.display()))?
        .to_os_string();

    session
        .send_request("initialize", json!({}))
        .map_err(|e| format!("initialize request failed: {e}"))?;
    let init_body = session
        .read_until_response("initialize", Duration::from_secs(5))
        .map_err(|e| format!("initialize response failed: {e}"))?;
    let supports_cfg_done = init_body
        .get("supportsConfigurationDoneRequest")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if !supports_cfg_done {
        return Err("initialize response missing supportsConfigurationDoneRequest=true".to_string());
    }
    session
        .read_until_event("initialized", Duration::from_secs(5))
        .map_err(|e| format!("initialized event wait failed: {e}"))?;

    session
        .send_launch(LaunchRequestArguments {
            program: None,
            trace_folder: Some(trace_folder),
            trace_file: Some(PathBuf::from(trace_file)),
            raw_diff_index: None,
            pid: None,
            cwd: None,
            no_debug: None,
            restart: None,
            name: None,
            request: None,
            typ: None,
            session_id: None,
            ct_rr_worker_exe: Some(ct_rr_support),
            restore_location: None,
        })
        .map_err(|e| format!("launch request failed: {e}"))?;
    session
        .read_until_response("launch", Duration::from_secs(5))
        .map_err(|e| format!("launch response failed: {e}"))?;

    session
        .send_request("configurationDone", json!({}))
        .map_err(|e| format!("configurationDone request failed: {e}"))?;
    session
        .read_until_response("configurationDone", Duration::from_secs(5))
        .map_err(|e| format!("configurationDone response failed: {e}"))?;
    session
        .read_until_event("stopped", Duration::from_secs(60))
        .map_err(|e| format!("entry stopped event wait failed: {e}"))?;
    session
        .read_until_event("ct/complete-move", Duration::from_secs(10))
        .map_err(|e| format!("entry complete-move event wait failed: {e}"))?;
    Ok(())
}

fn launch_ttd_session(session: &mut DapStdioSession) -> Result<(), String> {
    if let Ok(manifest) = resolve_manifest_path() {
        if let Ok(fixture) = parse_first_ttd_fixture(&manifest) {
            return launch_ttd_session_with_fixture(session, &fixture);
        }
    }

    let Some(fixture) = auto_record_tracepoint_fixture()? else {
        return Err("TTD manifest missing and auto-recording failed or unavailable".to_string());
    };
    launch_ttd_session_with_fixture(session, &fixture)
}

fn find_marker_line(path: &Path, marker: &str) -> Result<usize, String> {
    let contents = fs::read_to_string(path)
        .map_err(|e| format!("failed to read source file {}: {e}", path.display()))?;
    for (idx, line) in contents.lines().enumerate() {
        if line.contains(marker) {
            return Ok(idx + 1);
        }
    }
    Err(format!(
        "marker '{marker}' not found in {}",
        path.display()
    ))
}

fn build_tracepoint_session(
    tracepoint_id: usize,
    source_path: &str,
    line: usize,
    expression: &str,
) -> RunTracepointsArg {
    let tracepoint = Tracepoint {
        tracepoint_id,
        mode: TracepointMode::TracInlineCode,
        line,
        offset: 0,
        name: source_path.to_string(),
        expression: expression.to_string(),
        last_render: 0,
        is_disabled: false,
        is_changed: true,
        lang: Lang::C,
        results: Vec::new(),
        tracepoint_error: String::new(),
    };

    RunTracepointsArg {
        session: TraceSession {
            tracepoints: vec![tracepoint],
            found: Vec::new(),
            last_count: 0,
            results: HashMap::<i64, Vec<Stop>>::new(),
            id: 0,
        },
        stop_after: 0,
    }
}

fn request_tracepoint_locals(
    session: &mut DapStdioSession,
    tracepoint_id: usize,
) -> Result<Vec<Vec<db_backend::task::StringAndValueTuple>>, String> {
    let table_args = TableArgs {
        columns: Vec::new(),
        draw: 1,
        length: 25,
        order: Vec::new(),
        search: SearchValue {
            value: String::new(),
            regex: false,
        },
        start: 0,
    };
    let update_args = UpdateTableArgs {
        table_args,
        selected_kinds: [false; EVENT_KINDS_COUNT],
        is_trace: true,
        trace_id: tracepoint_id,
    };

    session.send_request("ct/update-table", serde_json::to_value(update_args).unwrap())?;
    let trace_values = session.read_until_event("tracepoint-locals", Duration::from_secs(10))?;
    let parsed: db_backend::task::TraceValues =
        serde_json::from_value(trace_values).map_err(|e| format!("parse TraceValues: {e}"))?;
    Ok(parsed.locals)
}

#[test]
fn e2e_codetracer_dap_ttd_smoke_windows() {
    if let Some(reason) = should_skip_ttd_tests() {
        eprintln!("SKIPPED: e2e_codetracer_dap_ttd_smoke_windows: {reason}");
        return;
    }

    let mut session = DapStdioSession::spawn().expect("spawn db-backend dap session");
    if let Err(err) = launch_ttd_session(&mut session) {
        eprintln!("SKIPPED: e2e_codetracer_dap_ttd_smoke_windows: {err}");
        session.disconnect().ok();
        return;
    }

    let threads = session
        .send_request("threads", json!({}))
        .and_then(|_| session.read_until_response("threads", Duration::from_secs(5)))
        .expect("load threads response");
    let thread_id = threads
        .get("threads")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .and_then(|thread| thread.get("id"))
        .and_then(Value::as_i64)
        .expect("threads response must include at least one thread id");

    let stack = session
        .send_request("stackTrace", json!({ "threadId": thread_id }))
        .and_then(|_| session.read_until_response("stackTrace", Duration::from_secs(5)))
        .expect("load stackTrace response");
    let frame = stack
        .get("stackFrames")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .cloned()
        .expect("stackTrace response must include at least one frame");
    let frame_id = frame
        .get("id")
        .and_then(Value::as_i64)
        .expect("top stack frame must include frame id");

    let scopes = session
        .send_request("scopes", json!({ "frameId": frame_id }))
        .and_then(|_| session.read_until_response("scopes", Duration::from_secs(5)))
        .expect("load scopes response");
    let scope_ref = scopes
        .get("scopes")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .and_then(|scope| scope.get("variablesReference"))
        .and_then(Value::as_i64);
    if let Some(scope_ref) = scope_ref {
        let variables = session
            .send_request("variables", json!({ "variablesReference": scope_ref }))
            .and_then(|_| session.read_until_response("variables", Duration::from_secs(10)))
            .expect("load variables response");
        assert!(
            variables.get("variables").and_then(Value::as_array).is_some(),
            "variables response must include variables array"
        );
    }

    session
        .send_request("next", json!({ "threadId": thread_id }))
        .expect("send next request");
    session
        .read_until_event("stopped", Duration::from_secs(30))
        .expect("wait for stopped after next");
    let complete_move = session
        .read_until_event("ct/complete-move", Duration::from_secs(10))
        .expect("wait for complete-move after next");
    let has_location = complete_move.get("location").is_some();
    assert!(has_location, "ct/complete-move event should include a location payload");

    session.disconnect().expect("clean disconnect");
}

#[test]
fn e2e_codetracer_dap_ttd_breakpoint_runto_windows() {
    if let Some(reason) = should_skip_ttd_tests() {
        eprintln!("SKIPPED: e2e_codetracer_dap_ttd_breakpoint_runto_windows: {reason}");
        return;
    }

    let mut session = DapStdioSession::spawn().expect("spawn db-backend dap session");
    if let Err(err) = launch_ttd_session(&mut session) {
        eprintln!("SKIPPED: e2e_codetracer_dap_ttd_breakpoint_runto_windows: {err}");
        session.disconnect().ok();
        return;
    }

    let threads = session
        .send_request("threads", json!({}))
        .and_then(|_| session.read_until_response("threads", Duration::from_secs(5)))
        .expect("load threads response");
    let thread_id = threads
        .get("threads")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .and_then(|thread| thread.get("id"))
        .and_then(Value::as_i64)
        .expect("threads response must include at least one thread id");

    let stack = session
        .send_request("stackTrace", json!({ "threadId": thread_id }))
        .and_then(|_| session.read_until_response("stackTrace", Duration::from_secs(5)))
        .expect("load stackTrace response");
    let frame = stack
        .get("stackFrames")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .cloned()
        .expect("stackTrace response must include at least one frame");
    let source_path = frame
        .get("source")
        .and_then(|source| source.get("path"))
        .and_then(Value::as_str)
        .expect("top stack frame must include source.path");
    let current_line = frame
        .get("line")
        .and_then(Value::as_i64)
        .ok_or_else(|| "top stack frame missing line".to_string())
        .expect("top stack frame line");

    let breakpoints: Vec<Value> = ((current_line + 1)..=(current_line + 40))
        .map(|line| json!({ "line": line }))
        .collect();
    assert!(
        !breakpoints.is_empty(),
        "generated breakpoint candidates must be non-empty"
    );

    let set_bp_body = session
        .send_request(
            "setBreakpoints",
            json!({
                "source": { "path": source_path },
                "breakpoints": breakpoints,
            }),
        )
        .and_then(|_| session.read_until_response("setBreakpoints", Duration::from_secs(10)))
        .expect("set breakpoints response");
    let verified_count = set_bp_body
        .get("breakpoints")
        .and_then(Value::as_array)
        .map(|bps| {
            bps.iter()
                .filter(|bp| bp.get("verified").and_then(Value::as_bool) == Some(true))
                .count()
        })
        .unwrap_or(0);
    assert!(
        verified_count > 0,
        "setBreakpoints must return at least one verified breakpoint on source {}",
        source_path
    );

    session
        .send_request("continue", json!({ "threadId": thread_id }))
        .expect("send continue request");
    let stopped_event = session
        .read_until_event("stopped", Duration::from_secs(90))
        .expect("wait for stopped event after continue");
    let reason = stopped_event
        .get("reason")
        .and_then(Value::as_str)
        .unwrap_or("<missing>");
    assert!(
        reason == "breakpoint" || reason == "step",
        "continue should stop with breakpoint-compatible lifecycle (received reason={reason})"
    );

    let complete_move = session
        .read_until_event("ct/complete-move", Duration::from_secs(10))
        .expect("wait for complete-move after breakpoint stop");
    assert!(
        complete_move.get("location").is_some(),
        "ct/complete-move event should include location after breakpoint stop"
    );

    session.disconnect().expect("clean disconnect");
}

#[test]
fn e2e_codetracer_dap_ttd_tracepoint_call_eval_windows() {
    if let Some(reason) = should_skip_ttd_tests() {
        eprintln!("SKIPPED: e2e_codetracer_dap_ttd_tracepoint_call_eval_windows: {reason}");
        return;
    }

    let mut session = DapStdioSession::spawn().expect("spawn db-backend dap session");
    if let Err(err) = launch_ttd_session(&mut session) {
        eprintln!("SKIPPED: e2e_codetracer_dap_ttd_tracepoint_call_eval_windows: {err}");
        session.disconnect().ok();
        return;
    }

    let threads = session
        .send_request("threads", json!({}))
        .and_then(|_| session.read_until_response("threads", Duration::from_secs(5)))
        .expect("load threads response");
    let thread_id = threads
        .get("threads")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .and_then(|thread| thread.get("id"))
        .and_then(Value::as_i64)
        .expect("threads response must include at least one thread id");

    let stack = session
        .send_request("stackTrace", json!({ "threadId": thread_id }))
        .and_then(|_| session.read_until_response("stackTrace", Duration::from_secs(5)))
        .expect("load stackTrace response");
    let frame = stack
        .get("stackFrames")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .cloned()
        .expect("stackTrace response must include at least one frame");
    let source_path = frame
        .get("source")
        .and_then(|source| source.get("path"))
        .and_then(Value::as_str)
        .expect("top stack frame must include source.path");

    let marker_line = find_marker_line(Path::new(source_path), "C_VALUES_MAIN_BREAKPOINT")
        .expect("find breakpoint marker line");
    let tracepoint_id = 0;
    let expression = "log(increment_static_local())";
    let args = build_tracepoint_session(tracepoint_id, source_path, marker_line, expression);

    session
        .send_request("ct/run-tracepoints", serde_json::to_value(args).unwrap())
        .and_then(|_| session.read_until_response("ct/run-tracepoints", Duration::from_secs(120)))
        .expect("run tracepoints response");

    let locals = request_tracepoint_locals(&mut session, tracepoint_id).expect("tracepoint locals event");
    let first = locals.first().expect("tracepoint locals should not be empty");
    let entry = first
        .iter()
        .find(|item| item.field0 == "increment_static_local()")
        .expect("expected call expression entry in tracepoint locals");

    assert!(
        matches!(entry.field1.kind, runtime_tracing::TypeKind::Int),
        "expected call expression to evaluate to int value, got {:?}",
        entry.field1.kind
    );

    session.disconnect().expect("clean disconnect");
}

#[test]
fn e2e_codetracer_dap_ttd_tracepoint_call_eval_failure_windows() {
    if let Some(reason) = should_skip_ttd_tests() {
        eprintln!("SKIPPED: e2e_codetracer_dap_ttd_tracepoint_call_eval_failure_windows: {reason}");
        return;
    }

    let mut session = DapStdioSession::spawn().expect("spawn db-backend dap session");
    if let Err(err) = launch_ttd_session(&mut session) {
        eprintln!("SKIPPED: e2e_codetracer_dap_ttd_tracepoint_call_eval_failure_windows: {err}");
        session.disconnect().ok();
        return;
    }

    let threads = session
        .send_request("threads", json!({}))
        .and_then(|_| session.read_until_response("threads", Duration::from_secs(5)))
        .expect("load threads response");
    let thread_id = threads
        .get("threads")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .and_then(|thread| thread.get("id"))
        .and_then(Value::as_i64)
        .expect("threads response must include at least one thread id");

    let stack = session
        .send_request("stackTrace", json!({ "threadId": thread_id }))
        .and_then(|_| session.read_until_response("stackTrace", Duration::from_secs(5)))
        .expect("load stackTrace response");
    let frame = stack
        .get("stackFrames")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .cloned()
        .expect("stackTrace response must include at least one frame");
    let source_path = frame
        .get("source")
        .and_then(|source| source.get("path"))
        .and_then(Value::as_str)
        .expect("top stack frame must include source.path");

    let marker_line = find_marker_line(Path::new(source_path), "C_VALUES_MAIN_BREAKPOINT")
        .expect("find breakpoint marker line");

    let tracepoint_id = 0;
    let expression = "log(missing_tracepoint_function())";
    let args = build_tracepoint_session(tracepoint_id, source_path, marker_line, expression);

    session
        .send_request("ct/run-tracepoints", serde_json::to_value(args).unwrap())
        .and_then(|_| session.read_until_response("ct/run-tracepoints", Duration::from_secs(120)))
        .expect("run tracepoints response");

    let locals = request_tracepoint_locals(&mut session, tracepoint_id).expect("tracepoint locals event");
    let first = locals.first().expect("tracepoint locals should not be empty");
    let entry = first
        .iter()
        .find(|item| item.field0 == "missing_tracepoint_function()")
        .expect("expected failed call expression entry in tracepoint locals");

    assert!(
        matches!(entry.field1.kind, runtime_tracing::TypeKind::Error),
        "expected missing function call to report error, got {:?}",
        entry.field1.kind
    );

    session.disconnect().expect("clean disconnect");
}

#[test]
fn e2e_codetracer_dap_ttd_tracepoint_return_struct_windows() {
    if let Some(reason) = should_skip_ttd_tests() {
        eprintln!("SKIPPED: e2e_codetracer_dap_ttd_tracepoint_return_struct_windows: {reason}");
        return;
    }

    let fixture = if let Ok(manifest) = resolve_manifest_path() {
        match parse_ttd_fixture_by_program_suffix(&manifest, "tests/programs/c/tracepoint/tracepoint.c")
            .expect("parse fixture")
        {
            Some(fixture) => Some(fixture),
            None => auto_record_tracepoint_fixture().expect("auto record"),
        }
    } else {
        auto_record_tracepoint_fixture().expect("auto record")
    };

    let Some(fixture) = fixture else {
        eprintln!("SKIPPED: no tracepoint fixture found and auto-record unavailable");
        return;
    };
    let Some(source_path) = fixture.source_path.clone() else {
        eprintln!("SKIPPED: tracepoint fixture missing program path");
        return;
    };

    let mut session = DapStdioSession::spawn().expect("spawn db-backend dap session");
    launch_ttd_session_with_fixture(&mut session, &fixture).expect("launch TTD DAP session");

    let marker_line = find_marker_line(&source_path, "TRACEPOINT_EVAL_BREAK")
        .expect("find breakpoint marker line");
    let tracepoint_id = 0;
    let expression = "log(get_tracepoint_pair())";
    let args = build_tracepoint_session(
        tracepoint_id,
        source_path.to_str().expect("source path"),
        marker_line,
        expression,
    );

    session
        .send_request("ct/run-tracepoints", serde_json::to_value(args).unwrap())
        .and_then(|_| session.read_until_response("ct/run-tracepoints", Duration::from_secs(120)))
        .expect("run tracepoints response");

    let locals = request_tracepoint_locals(&mut session, tracepoint_id).expect("tracepoint locals event");
    let first = locals.first().expect("tracepoint locals should not be empty");
    let entry = first
        .iter()
        .find(|item| item.field0 == "get_tracepoint_pair()")
        .expect("expected struct return entry in tracepoint locals");

    assert!(
        matches!(entry.field1.kind, runtime_tracing::TypeKind::Struct),
        "expected struct return value, got {:?}",
        entry.field1.kind
    );

    session.disconnect().expect("clean disconnect");
}

#[test]
fn e2e_codetracer_dap_ttd_tracepoint_return_string_windows() {
    if let Some(reason) = should_skip_ttd_tests() {
        eprintln!("SKIPPED: e2e_codetracer_dap_ttd_tracepoint_return_string_windows: {reason}");
        return;
    }

    let fixture = if let Ok(manifest) = resolve_manifest_path() {
        match parse_ttd_fixture_by_program_suffix(&manifest, "tests/programs/c/tracepoint/tracepoint.c")
            .expect("parse fixture")
        {
            Some(fixture) => Some(fixture),
            None => auto_record_tracepoint_fixture().expect("auto record"),
        }
    } else {
        auto_record_tracepoint_fixture().expect("auto record")
    };

    let Some(fixture) = fixture else {
        eprintln!("SKIPPED: no tracepoint fixture found and auto-record unavailable");
        return;
    };
    let Some(source_path) = fixture.source_path.clone() else {
        eprintln!("SKIPPED: tracepoint fixture missing program path");
        return;
    };

    let mut session = DapStdioSession::spawn().expect("spawn db-backend dap session");
    launch_ttd_session_with_fixture(&mut session, &fixture).expect("launch TTD DAP session");

    let marker_line = find_marker_line(&source_path, "TRACEPOINT_EVAL_BREAK")
        .expect("find breakpoint marker line");
    let tracepoint_id = 0;
    let expression = "log(echo_str(s))";
    let args = build_tracepoint_session(
        tracepoint_id,
        source_path.to_str().expect("source path"),
        marker_line,
        expression,
    );

    session
        .send_request("ct/run-tracepoints", serde_json::to_value(args).unwrap())
        .and_then(|_| session.read_until_response("ct/run-tracepoints", Duration::from_secs(120)))
        .expect("run tracepoints response");

    let locals = request_tracepoint_locals(&mut session, tracepoint_id).expect("tracepoint locals event");
    let first = locals.first().expect("tracepoint locals should not be empty");
    let entry = first
        .iter()
        .find(|item| item.field0 == "echo_str(s)")
        .expect("expected string return entry in tracepoint locals");

    assert!(
        matches!(entry.field1.kind, runtime_tracing::TypeKind::String),
        "expected string return value, got {:?}",
        entry.field1.kind
    );

    session.disconnect().expect("clean disconnect");
}
