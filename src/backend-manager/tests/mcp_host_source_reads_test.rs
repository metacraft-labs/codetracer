//! No MCP tool returns a line of a host file a recording lists, unless the
//! server was started with `--allow-host-source-reads`.
//!
//! A recording's source list, and the paths its steps are on, are recording
//! content: a recording made from other people's traffic can name any file
//! on the machine that replays it and place steps on that file's lines.
//! `read_source_file` refuses such a file without the option; this test is
//! about every OTHER way its lines could reach an agent, which all go
//! through the replay backend the daemon starts:
//!
//! * `get_value_origin` and `resolve_variable_step`, whose hops carry the
//!   source line that produced a value (`sourceText`, `assignment`);
//! * `exec_script`, through the Python API's location, stack, value-trace
//!   (flow), `value_origin` and `read_source` calls (on this recording the
//!   value trace lists only recorded variables under either setting, so it
//!   is checked for leaks, not as a carrier);
//! * `read_source_file` and the `trace:///<path>/source/<file>` resource.
//!
//! The recording here lists, and steps through, a Python module that lies
//! outside its recorded working directory and has no copy in the recording.
//! Every line of the module carries a marker identifier.  Without the
//! option no tool result may contain the marker, and the refusals say that
//! host source reads are off; with it, the same queries return the module's
//! lines (so a refusal is not an empty trace or a broken query).  As the
//! negative control, the same recording with an embedded `files/` copy that
//! differs from the host module returns the copy's lines without the
//! option.
//!
//! One daemon serves both MCP servers, the way one daemon serves every
//! client on a machine.  The setting travels with each request, so the
//! daemon keeps a separate replay backend per setting: the test checks that
//! each server gets its own behaviour, in both orders, and that the backend
//! launched for the server without the option was launched with
//! `hostSourceReads: false` and is sent every DAP `source` request with
//! `allowWorkingTree: false`.
//!
//! ## What is real, and the one thing that is not a CodeTracer component
//!
//! The MCP servers (`trace mcp`), the daemon, the `replay-server` and the
//! Python API are the production code, over their real stdio and socket
//! transports.  The recordings are written by the production CTFS writer
//! (`codetracer_trace_writer`), which needs no recorder toolchain.  No
//! component is mocked.
//!
//! What the daemon sends each replay backend is observed by a byte tap: the
//! daemon is pointed (`CODETRACER_REPLAY_SERVER_CMD`) at a small script that
//! starts the real `replay-server` on a socket of its own and carries every
//! byte between it and the daemon unchanged, keeping a copy of what the
//! daemon sent.  It answers nothing itself and alters nothing, so it is a
//! tap, not a stand-in for the backend.  It is a Python script because the
//! daemon starts the backend as a separate executable.
//!
//! A missing `replay-server` or `python3` fails the test.  It is never a skip.

#![cfg(unix)]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

#[path = "support/mcp_harness.rs"]
mod mcp_harness;

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use mcp_harness::*;
use serde_json::{Value, json};

/// The marker every line of the host module carries.  Its absence from a
/// tool result shows that no line of the module reached it.
const HOST_MARK: &str = "HOSTONLY_7f3a";
/// The marker every line of the recording's embedded copy carries.
const COPY_MARK: &str = "RECORDEDCOPY_51c2";
/// What the refusals name as the reason.
const REASON: &str = "host source reads are off";

/// The module the recording steps through, as `write_recording` records it
/// (steps on lines 2, 4, 4, 4 and 5, `total` written on line 4).  `mark`
/// is an identifier on every line, so it would surface both as line text
/// and as an expression the flow parses out of line 4.
fn module_source(mark: &str) -> String {
    format!(
        "def main():  # {mark}\n    total = 0  # {mark}\n    for i in range(3):  # {mark}\n        \
         total += i + 0 * {mark}\n    return total  # {mark}\n"
    )
}

/// The tap the daemon starts in place of the replay server: it starts the
/// real one on `<daemon socket>.tap`, connects to the daemon's socket, and
/// carries bytes both ways, appending what the daemon sends to
/// `<tap dir>/<daemon socket name>.log`.
const TAP_SCRIPT: &str = r#"import os, socket, subprocess, sys, threading
daemon_socket = sys.argv[-1]
real = os.environ["CT_TEST_REAL_REPLAY_SERVER"]
log_path = os.path.join(os.environ["CT_TEST_TAP_DIR"], os.path.basename(daemon_socket) + ".log")
tap_socket = daemon_socket + ".tap"
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(tap_socket)
listener.listen(1)
child = subprocess.Popen([real, *sys.argv[1:-1], tap_socket])
backend, _ = listener.accept()
daemon = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
daemon.connect(daemon_socket)
log = open(log_path, "ab", buffering=0)
def pump(src, dst, record):
    while True:
        try:
            data = src.recv(65536)
        except OSError:
            break
        if not data:
            break
        if record:
            log.write(data)
        try:
            dst.sendall(data)
        except OSError:
            break
    try:
        dst.shutdown(socket.SHUT_WR)
    except OSError:
        pass
threading.Thread(target=pump, args=(daemon, backend, True), daemon=True).start()
threading.Thread(target=pump, args=(backend, daemon, False), daemon=True).start()
sys.exit(child.wait())
"#;

/// The `python3` the tap runs under: the first on `PATH`.  Missing fails.
fn python3() -> PathBuf {
    let path = std::env::var_os("PATH").expect("PATH is set");
    std::env::split_paths(&path)
        .map(|dir| dir.join("python3"))
        .find(|candidate| candidate.is_file())
        .expect("python3 is on PATH (the backend tap and exec_script need it)")
}

/// Writes the tap into `dir` and returns the executable the daemon starts.
fn write_tap(dir: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(dir).unwrap();
    let script = dir.join("replay_tap.py");
    std::fs::write(&script, TAP_SCRIPT).unwrap();
    let launcher = dir.join("replay-tap");
    std::fs::write(
        &launcher,
        format!(
            "#!/bin/sh\nexec '{}' -I '{}' \"$@\"\n",
            python3().display(),
            script.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o755)).unwrap();
    launcher
}

/// What one replay backend was sent: its `launch` arguments and every DAP
/// `source` request.
#[derive(Debug)]
struct BackendLog {
    launch: Value,
    sources: Vec<Value>,
}

/// Every backend the tap carried, from its logs in `tap_dir`.
fn backend_logs(tap_dir: &Path) -> Vec<BackendLog> {
    let mut logs = Vec::new();
    for entry in std::fs::read_dir(tap_dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension() != Some(OsStr::new("log")) {
            continue;
        }
        let messages = dap_messages(&std::fs::read(&path).unwrap());
        let launch = messages
            .iter()
            .find(|m| m["command"] == "launch")
            .map(|m| m["arguments"].clone())
            .unwrap_or_else(|| panic!("{} carries no launch request", path.display()));
        let sources = messages
            .iter()
            .filter(|m| m["command"] == "source")
            .map(|m| m["arguments"].clone())
            .collect();
        logs.push(BackendLog { launch, sources });
    }
    logs
}

/// The results of every query this test makes of one recording.
#[derive(Debug)]
struct Probe {
    origin: Result<String, String>,
    step: Result<String, String>,
    script: Result<String, String>,
    read: Result<String, String>,
    resource: Result<String, String>,
}

impl Probe {
    /// Every text the tools returned, results and errors alike.
    fn texts(&self) -> Vec<(&'static str, &str)> {
        fn text(r: &Result<String, String>) -> &str {
            match r {
                Ok(t) | Err(t) => t,
            }
        }
        vec![
            ("get_value_origin", text(&self.origin)),
            ("resolve_variable_step", text(&self.step)),
            ("exec_script", text(&self.script)),
            ("read_source_file", text(&self.read)),
            ("source resource", text(&self.resource)),
        ]
    }

    /// The tools whose text contains `mark`.
    fn carrying(&self, mark: &str) -> Vec<&'static str> {
        self.texts()
            .into_iter()
            .filter(|(_, text)| text.contains(mark))
            .map(|(tool, _)| tool)
            .collect()
    }

    /// The exec_script entry `name` (see `SCRIPT`).
    fn script_entry(&self, name: &str) -> String {
        let stdout = self
            .script
            .as_ref()
            .unwrap_or_else(|e| panic!("exec_script failed: {e}"));
        let line = stdout
            .lines()
            .rev()
            .find(|l| l.starts_with('{'))
            .unwrap_or_else(|| panic!("exec_script printed no JSON: {stdout}"));
        let out: Value = serde_json::from_str(line).expect("the script's JSON line");
        out[name].as_str().unwrap_or_default().to_owned()
    }
}

/// The exec_script program: stops on line 5 of `{path}` and asks the
/// Python API for everything that carries source-derived text.  Each call is
/// reported, a failure as `ERROR <type>: <message>`.
const SCRIPT: &str = r#"import json
P = {path}
out = {}
def safe(name, f):
    try:
        out[name] = repr(f())
    except Exception as e:
        out[name] = "ERROR " + type(e).__name__ + ": " + str(e)
safe("start", lambda: trace.location)
safe("breakpoint", lambda: trace.add_breakpoint(P, 5))
safe("continue", lambda: trace.continue_forward())
safe("stack", lambda: trace.stack_trace())
safe("origin", lambda: trace.value_origin("total"))
safe("flow", lambda: trace.value_trace(P, 4))
safe("read_source", lambda: trace.read_source(P))
print(json.dumps(out))
"#;

/// Every query of the test against `trace_dir`, whose program is `module`.
async fn probe(mcp: &mut Mcp, trace_dir: &Path, module: &Path) -> Probe {
    let module_str = module.to_str().unwrap();
    let origin_args = json!({
        "trace_path": trace_dir, "path": module_str, "line": 5, "variable": "total",
    });
    let origin = mcp.call_tool("get_value_origin", origin_args.clone()).await;
    let step = mcp.call_tool("resolve_variable_step", origin_args).await;
    let script = mcp
        .call_tool(
            "exec_script",
            json!({
                "trace_path": trace_dir,
                "script": SCRIPT.replace("{path}", &format!("{module_str:?}")),
                "timeout_seconds": 120,
            }),
        )
        .await;
    let read = mcp
        .call_tool(
            "read_source_file",
            json!({"trace_path": trace_dir, "file_path": module_str}),
        )
        .await;
    let resource = mcp.read_source_resource(trace_dir, module_str).await;
    Probe {
        origin,
        step,
        script,
        read,
        resource,
    }
}

#[tokio::test]
async fn t_mcp_tools_return_no_listed_host_source_without_opt_in() {
    let replay_server = replay_server();
    let server = server_binary();
    let (_root, root) = short_root("ct-hsr-");

    // Layout:
    //   <root>/host/secret_module.py     the program, outside the workdir, no copy
    //   <root>/project/                   the recorded working directory
    //   <root>/trace-a/trace.ct           the recording
    //   <root>/trace-b/trace.ct           the same recording ...
    //   <root>/trace-b/files/<module>     ... with a copy differing from the host
    let host_source = module_source(HOST_MARK);
    let copy_source = module_source(COPY_MARK);
    let module = root.join("host/secret_module.py");
    std::fs::create_dir_all(module.parent().unwrap()).unwrap();
    std::fs::write(&module, &host_source).unwrap();
    let workdir = root.join("project");
    std::fs::create_dir_all(&workdir).unwrap();
    let trace_a = root.join("trace-a");
    let trace_b = root.join("trace-b");
    for trace in [&trace_a, &trace_b] {
        std::fs::create_dir_all(trace).unwrap();
        write_recording(trace, &workdir, &module, &[]);
    }
    let copy = trace_b.join("files").join(without_root(&module));
    std::fs::create_dir_all(copy.parent().unwrap()).unwrap();
    std::fs::write(&copy, &copy_source).unwrap();

    // Vacuity guard: the module is readable by this user, the user every
    // server and backend runs as, and lies outside the recorded workdir.
    assert_eq!(std::fs::read_to_string(&module).unwrap(), host_source);
    assert!(!module.starts_with(&workdir));

    let tap_dir = root.join("tap");
    let tap = write_tap(&tap_dir);
    // The Python API `exec_script` imports: this checkout's, named
    // explicitly so the daemon does not depend on how it was built.
    let python_api = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../python-api")
        .canonicalize()
        .expect("the checkout's python-api directory");
    let (mut daemon, socket) = start_daemon_with_env(
        &server,
        &root,
        &tap,
        &[
            ("CT_TEST_REAL_REPLAY_SERVER", replay_server.as_os_str()),
            ("CT_TEST_TAP_DIR", tap_dir.as_os_str()),
            ("CODETRACER_PYTHON_API_PATH", python_api.as_os_str()),
        ],
    )
    .await;

    let mut refused = start_mcp(&server, &root, &socket, &with_script_opt_in(&server, &[])).await;
    let mut allowed = start_mcp(
        &server,
        &root,
        &socket,
        &with_script_opt_in(&server, &["--allow-host-source-reads"]),
    )
    .await;
    let mut wrong: Vec<String> = Vec::new();

    // 1. Without the option, first: nothing of the module, and the reason.
    let first = probe(&mut refused, &trace_a, &module).await;
    let leaked = first.carrying(HOST_MARK);
    if !leaked.is_empty() {
        wrong.push(format!(
            "without the option, {leaked:?} returned the host module's text: {first:#?}"
        ));
    }
    let script_source = first.script_entry("read_source");
    if !script_source.contains(REASON) {
        wrong.push(format!(
            "without the option, the Python API's read_source did not say why it refused: {script_source}"
        ));
    }
    // The origin tools name the reason their source text is empty.
    for (tool, result) in [
        ("get_value_origin", &first.origin),
        ("resolve_variable_step", &first.step),
    ] {
        match result {
            Ok(text)
                if text.contains("no copy of") && text.contains("--allow-host-source-reads") => {}
            other => wrong.push(format!(
                "without the option, {tool} did not say why its source text is empty: {other:?}"
            )),
        }
    }
    if !matches!(&first.read, Err(e) if e.contains("not embedded")) {
        wrong.push(format!(
            "without the option, read_source_file was not refused as not embedded: {:?}",
            first.read
        ));
    }

    // 2. With the option, through the same daemon: the module's lines.
    let with = probe(&mut allowed, &trace_a, &module).await;
    for (tool, result) in [
        ("get_value_origin", &with.origin),
        ("resolve_variable_step", &with.step),
    ] {
        match result {
            Ok(text) if text.contains(&format!("total += i + 0 * {HOST_MARK}")) => {}
            other => wrong.push(format!(
                "with the option, {tool} did not return the module's line 4: {other:?}"
            )),
        }
    }
    if !with.script_entry("origin").contains(HOST_MARK) {
        wrong.push(format!(
            "with the option, the Python API's value_origin did not carry the module's line: {}",
            with.script_entry("origin")
        ));
    }
    let script_source = with.script_entry("read_source");
    if !script_source.contains(HOST_MARK) || script_source.starts_with("ERROR") {
        wrong.push(format!(
            "with the option, the Python API's read_source did not return the module: {script_source}"
        ));
    }
    if with.read.as_deref() != Ok(host_source.as_str()) {
        wrong.push(format!(
            "with the option, read_source_file did not serve the module: {:?}",
            with.read
        ));
    }
    if with.resource.as_deref() != Ok(host_source.as_str()) {
        wrong.push(format!(
            "with the option, the source resource did not serve the module: {:?}",
            with.resource
        ));
    }

    // 3. Without the option again, after a backend that reads the host
    //    exists for the same trace: still nothing of the module.
    let again = probe(&mut refused, &trace_a, &module).await;
    let leaked = again.carrying(HOST_MARK);
    if !leaked.is_empty() {
        wrong.push(format!(
            "without the option, after a server with it opened the trace, {leaked:?} returned the host module's text"
        ));
    }

    // Negative control: the recording's own copy is served without the
    // option, and the host module still is not.
    let control = probe(&mut refused, &trace_b, &module).await;
    for (tool, result) in [
        ("get_value_origin", &control.origin),
        ("resolve_variable_step", &control.step),
    ] {
        match result {
            Ok(text) if text.contains(&format!("total += i + 0 * {COPY_MARK}")) => {}
            other => wrong.push(format!(
                "without the option, {tool} did not return the copy's line 4: {other:?}"
            )),
        }
    }
    if control.read.as_deref() != Ok(copy_source.as_str()) {
        wrong.push(format!(
            "without the option, read_source_file did not serve the copy: {:?}",
            control.read
        ));
    }
    if !control.script_entry("read_source").contains(COPY_MARK) {
        wrong.push(format!(
            "without the option, the Python API's read_source did not return the copy: {}",
            control.script_entry("read_source")
        ));
    }
    let leaked = control.carrying(HOST_MARK);
    if !leaked.is_empty() {
        wrong.push(format!("without the option, {leaked:?} returned the host module's text for the copy's recording"));
    }

    refused.stop().await;
    allowed.stop().await;
    shutdown_daemon(&socket, &mut daemon).await;

    // What the daemon sent the backends: one per (recording, setting), each
    // launched with its setting, and every `source` request of a backend
    // without host reads sent `allowWorkingTree: false`.
    let logs = backend_logs(&tap_dir);
    let launched = |trace: &Path, reads: bool| {
        logs.iter()
            .filter(|log| {
                log.launch["traceFolder"] == json!(trace)
                    && log.launch["hostSourceReads"] == json!(reads)
            })
            .count()
    };
    // A trace is opened again after `exec_script` closes it, so a setting
    // may have had several backends over the test; what matters is that
    // each setting the servers asked for got backends launched with it, and
    // none launched with the other.
    for (trace, reads, present) in [
        (&trace_a, false, true),
        (&trace_a, true, true),
        (&trace_b, false, true),
        (&trace_b, true, false),
    ] {
        let count = launched(trace, reads);
        if (count > 0) != present {
            wrong.push(format!(
                "{count} backend(s) for {} launched with hostSourceReads: {reads}: {:#?}",
                trace.display(),
                logs.iter().map(|l| &l.launch).collect::<Vec<_>>()
            ));
        }
    }
    let mut refused_sources = 0;
    for log in &logs {
        let reads = log.launch["hostSourceReads"].as_bool();
        if reads.is_none() {
            wrong.push(format!(
                "a backend was launched without hostSourceReads: {}",
                log.launch
            ));
        }
        for request in &log.sources {
            if request["allowWorkingTree"].as_bool() != reads {
                wrong.push(format!(
                    "a source request to a backend launched with hostSourceReads {reads:?} carried {request}"
                ));
            }
            if reads == Some(false) {
                refused_sources += 1;
            }
        }
    }
    if refused_sources == 0 {
        wrong.push("no source request reached a backend without host reads, so allowWorkingTree went unchecked".into());
    }

    assert!(
        wrong.is_empty(),
        "the host-read setting does not hold across the tools:\n{}",
        wrong.join("\n")
    );
}
