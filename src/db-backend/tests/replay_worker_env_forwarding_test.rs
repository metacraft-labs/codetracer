//! `ct replay --thread-sync-order` / `--os-simulation` reach the native
//! replay engine as their environment twins (`CT_THREAD_SYNC_ORDER`,
//! `CT_OS_SIMULATION`) — codetracer-specs `CLI/ct/replay.md`, "Options". This
//! test pins db-backend's hop of that chain.
//!
//! # The chain, and which hop this is
//!
//! `ct replay` validates the options and publishes the twins into its own
//! environment (`src/ct/trace/replay_backend_env.nim`). From there they travel
//! `ct` -> Electron -> backend-manager -> **db-backend `dap-server`** ->
//! `ct-native-replay replay-worker` -> `ct-mcr`, by inheritance only: no hop
//! has an argument slot for them. So the property this hop must keep is that
//! `ReplayWorker::start` hands the worker the environment the `dap-server`
//! process was started with. An `env_clear()` there, or a hand-built
//! environment that lists only the variables someone remembered, would drop
//! both options silently: the replay would still run, under the engine's
//! defaults, and nothing would report it. That is why this is a test and not
//! a code-reading claim.
//!
//! The hop before this one (`ct` itself) is
//! `src/tests/cli/replay_backend_env_e2e_test.nim`.
//!
//! # Why a stub worker and not the real one
//!
//! Mocking justification (workspace policy on mock objects): the WORKER is
//! replaced, through the launch argument `ctRRWorkerExe`, by a script that
//! writes the two variables it received to a file and exits. What is under
//! test is what arrives at the worker's door; the real `ct-native-replay`
//! would consume it rather than report it, and it is not built by `cargo
//! test` in this crate. The real `dap-server` binary, its DAP launch handling
//! and the real `ReplayWorker::start` spawn are exercised. This is the
//! stub-worker technique of `tests/replay_worker_quota_error_test.rs`, made to
//! run on Windows too (a `.cmd` script there, `/bin/sh` elsewhere), because
//! Windows is where `--thread-sync-order` means something.

use db_backend::dap::{self, DapClient, DapMessage};
use db_backend::transport::DapTransport;
use serde_json::json;
use std::io::{BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

const THREAD_SYNC_ORDER_ENV: &str = "CT_THREAD_SYNC_ORDER";
const OS_SIMULATION_ENV: &str = "CT_OS_SIMULATION";

/// Write a stub worker that records the replay-engine twins it inherited into
/// `capture` (one `NAME=value` line per variable that is SET) and exits 1
/// without creating a socket.
fn write_env_capturing_worker(dir: &Path, capture: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        // `set NAME` prints `NAME=value` for every variable whose name starts
        // with NAME and fails when there is none, which is what lets an unset
        // variable leave no line. `if defined` keeps the two independent.
        let path = dir.join("env-worker.cmd");
        let mut file = std::fs::File::create(&path).expect("create stub worker");
        write!(
            file,
            "@echo off\r\n\
             type nul > \"{cap}\"\r\n\
             if defined {tso} (set {tso}>> \"{cap}\")\r\n\
             if defined {osim} (set {osim}>> \"{cap}\")\r\n\
             exit /b 1\r\n",
            cap = capture.display(),
            tso = THREAD_SYNC_ORDER_ENV,
            osim = OS_SIMULATION_ENV,
        )
        .expect("write stub worker");
        path
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join("env-worker");
        let mut file = std::fs::File::create(&path).expect("create stub worker");
        write!(
            file,
            "#!/bin/sh\n\
             : > '{cap}'\n\
             if [ -n \"${{{tso}+x}}\" ]; then printf '%s\\n' \"{tso}=${tso}\" >> '{cap}'; fi\n\
             if [ -n \"${{{osim}+x}}\" ]; then printf '%s\\n' \"{osim}=${osim}\" >> '{cap}'; fi\n\
             exit 1\n",
            cap = capture.display(),
            tso = THREAD_SYNC_ORDER_ENV,
            osim = OS_SIMULATION_ENV,
        )
        .expect("write stub worker");
        drop(file);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod stub worker");
        path
    }
}

/// A trace folder whose only content is an empty `rr/` directory: the shape
/// `dap_server::resolve_replay_trace_path` routes down the replay-worker path
/// (`replay_worker_quota_error_test.rs`, `write_rr_trace_folder`). Nothing
/// reads inside it — the stub exits before any trace byte is touched.
fn write_rr_trace_folder(dir: &Path) -> PathBuf {
    let folder = dir.join("trace");
    std::fs::create_dir_all(folder.join("rr")).expect("create rr trace folder");
    folder
}

fn terminate_child(child: &mut Child) {
    child.kill().ok();
    child.wait().ok();
}

/// Run the real `dap-server` with `twins` in its environment (and neither twin
/// otherwise), launch the stub worker through it, and return the lines the
/// worker recorded, sorted.
fn worker_saw(twins: &[(&str, &str)]) -> Vec<String> {
    let temp = tempfile::tempdir().expect("create temp dir");
    let capture = temp.path().join("worker-saw.txt");
    let stub = write_env_capturing_worker(temp.path(), &capture);
    let trace_folder = write_rr_trace_folder(temp.path());

    let mut command = Command::new(env!("CARGO_BIN_EXE_replay-server"));
    command
        .arg("dap-server")
        .arg("--stdio")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        // The stub exits at once; pinning the startup timeout keeps a stub
        // that never ran from stretching the test.
        .env("CODETRACER_REPLAY_WORKER_STARTUP_TIMEOUT_SECS", "5")
        // Whatever the invoking shell has, the row decides.
        .env_remove(THREAD_SYNC_ORDER_ENV)
        .env_remove(OS_SIMULATION_ENV);
    for (name, value) in twins {
        command.env(name, value);
    }
    let mut child = command
        .spawn()
        .unwrap_or_else(|err| panic!("failed to spawn db-backend: {err}"));

    let mut writer = child.stdin.take().expect("missing child stdin");
    let reader_stdout = child.stdout.take().expect("missing child stdout");
    // Drain stdout so the server never blocks on a full pipe.
    let (tx, _rx) = mpsc::channel::<DapMessage>();
    thread::spawn(move || {
        let mut reader = BufReader::new(reader_stdout);
        while let Ok(msg) = dap::read_dap_message_from_reader(&mut reader) {
            if tx.send(msg).is_err() {
                break;
            }
        }
    });

    let mut client = DapClient::default();
    for request in [
        client.request("initialize", json!({})),
        client.request(
            "launch",
            json!({
                "traceFolder": trace_folder,
                "ctRRWorkerExe": stub,
            }),
        ),
        client.request("configurationDone", json!({})),
    ] {
        writer
            .send(&request)
            .unwrap_or_else(|err| panic!("failed to send DAP request: {err}"));
    }

    // The stub creates the capture file first and then appends its lines, so
    // wait for the file to appear and then settle briefly for the appends.
    // The stub exits right after them; the server is killed below either way.
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline && !capture.exists() {
        thread::sleep(Duration::from_millis(50));
    }
    thread::sleep(Duration::from_millis(500));
    terminate_child(&mut child);

    let text = std::fs::read_to_string(&capture)
        .unwrap_or_else(|err| panic!("the stub worker never ran (no {}): {err}", capture.display()));
    let mut lines: Vec<String> = text
        .lines()
        .map(|line| line.trim().to_string())
        .filter(|line| !line.is_empty())
        .collect();
    lines.sort();
    lines
}

#[test]
fn replay_worker_inherits_replay_engine_options() {
    let saw = worker_saw(&[
        (THREAD_SYNC_ORDER_ENV, "per-object"),
        (OS_SIMULATION_ENV, "strong-kernel"),
    ]);
    assert_eq!(
        saw,
        vec![
            "CT_OS_SIMULATION=strong-kernel".to_string(),
            "CT_THREAD_SYNC_ORDER=per-object".to_string(),
        ],
        "the replay worker must inherit the replay-engine twins `ct replay` publishes; \
         a dropped twin means ReplayWorker::start no longer passes its environment on"
    );
}

#[test]
fn replay_worker_sees_no_twin_that_was_not_given() {
    // Negative control: the stub reports only what it inherited, so the row
    // above discriminates on the server's environment rather than on
    // anything the stub or the launch request invents.
    let saw = worker_saw(&[]);
    assert!(
        saw.is_empty(),
        "with neither twin in the server's environment the worker must see neither: {saw:?}"
    );
}
