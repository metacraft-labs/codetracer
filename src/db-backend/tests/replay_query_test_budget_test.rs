//! A slow worker must get the response budget already allowed by the native
//! DAP test client, rather than a hidden, shorter production timeout.
//!
//! The real DapStdioClient spawns the real replay-server. Only the worker is
//! scripted: its real Unix socket deliberately withholds RunToEntry for eleven
//! seconds, recreating the scheduling delay without saturating a shared host.
//! A real rr/GDB worker cannot be delayed deterministically at one query. The
//! stub then supplies a fixed location, which must reach ct/complete-move.
//! Override cases run in separate processes so no test mutates an environment
//! that another test or client reader thread could be using.

#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::process::Command;
use std::time::Duration;

use ct_dap_client::client::DapStdioClient;
use ct_dap_client::types::LaunchRequestArguments;
use serde_json::Value;

const TIMEOUT: &str = "CODETRACER_REPLAY_QUERY_TIMEOUT_SECS";
const CASE: &str = "CT_REPLAY_BUDGET_TEST_CASE";

#[test]
fn replay_queries_use_the_native_test_clients_budget_and_overrides() {
    let Ok(case) = std::env::var(CASE) else {
        for case in ["default", "ambient", "explicit", "fractional", "production"] {
            let output = Command::new(std::env::current_exe().expect("test executable"))
                .args([
                    "--exact",
                    "replay_queries_use_the_native_test_clients_budget_and_overrides",
                    "--nocapture",
                ])
                .env(CASE, case)
                .env_remove(TIMEOUT)
                .env("CODETRACER_DAP_CLIENT_TIMEOUT_SCALE", "6")
                .envs((case == "ambient" || case == "explicit").then_some((TIMEOUT, "1")))
                .output()
                .expect("run isolated budget case");
            assert!(
                output.status.success(),
                "{case}: {}\n{}\n{}",
                output.status,
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
        return;
    };

    let temp = tempfile::tempdir().expect("test directory");
    let trace = temp.path().join("trace");
    std::fs::create_dir_all(trace.join("rr")).expect("rr trace directory");
    let capture = temp.path().join("worker.json");
    let worker = temp.path().join("worker");
    std::fs::write(
        &worker,
        r#"#!/usr/bin/env python3
import json, os, pathlib, socket, sys, time
args = sys.argv
name = args[args.index('--name') + 1]
index = args[args.index('--index') + 1]
run = pathlib.Path(os.environ['CODETRACER_RUNTIME_DIR']) / ('run-' + os.environ['CODETRACER_RUN_ID'])
run.mkdir(parents=True, exist_ok=True)
listener = socket.socket(socket.AF_UNIX)
listener.bind(str(run / ('ct_native_replay_' + name + '_' + index + '_from_.sock')))
listener.listen(1)
stream, _ = listener.accept()
reader = stream.makefile('rb')
location = {'path': '/delayed-worker.c', 'line': 42, 'functionName': 'delayed_entry', 'rrTicks': 7}
for line in reader:
    query = json.loads(line)['kind']
    if query == 'RunToEntry':
        pathlib.Path(os.environ['CT_BUDGET_CAPTURE']).write_text(json.dumps({'timeout': os.environ.get('CODETRACER_REPLAY_QUERY_TIMEOUT_SECS'), 'query': query}))
        time.sleep(float(os.environ['CT_BUDGET_DELAY']))
        answer = True
    elif query == 'LoadLocationWithSourcemap':
        answer = {'location': location}
    elif query == 'LoadLocation':
        answer = location
    elif query == 'SupportsInstructionStepping':
        answer = False
    elif query == 'LoadAllEvents':
        answer = {'events': [], 'firstEvents': [], 'contents': ''}
    elif query == 'DeleteBreakpoints':
        answer = True
    else:
        raise RuntimeError('unexpected replay query: ' + repr(query))
    stream.sendall((json.dumps(answer) + '\n').encode())
"#,
    )
    .expect("worker script");
    std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o755)).expect("executable worker");

    let home = temp.path().join("home");
    let runtime = temp.path().join("r");
    let mut envs = vec![
        ("CODETRACER_HOME", home.to_str().unwrap()),
        ("CODETRACER_RUNTIME_DIR", runtime.to_str().unwrap()),
        ("CT_COOP_QUERY", "0"),
        ("CT_BUDGET_CAPTURE", capture.to_str().unwrap()),
        (
            "CT_BUDGET_DELAY",
            match case.as_str() {
                "default" | "production" => "11",
                "fractional" => "0",
                _ => "2",
            },
        ),
    ];
    if case == "explicit" {
        // Explicit per-spawn configuration wins over the inherited one.
        envs.push((TIMEOUT, "20"));
    }
    if case == "production" {
        // An invalid explicit value is preserved and the real backend uses
        // its production fallback. Pin that unchanged ten-second default.
        envs.push((TIMEOUT, "invalid"));
    }
    if case == "fractional" {
        // Parent-side scale is set before the client exists in this isolated
        // single-test process. No reader threads exist yet.
        unsafe { std::env::set_var("CODETRACER_DAP_CLIENT_TIMEOUT_SCALE", "1.25") };
    }
    let mut client = DapStdioClient::spawn_with_envs(std::path::Path::new(env!("CARGO_BIN_EXE_replay-server")), &envs)
        .expect("spawn replay-server");
    client.initialize().expect("initialize");
    client
        .launch(LaunchRequestArguments {
            trace_folder: Some(trace),
            ct_rr_worker_exe: Some(worker),
            ..Default::default()
        })
        .expect("launch acknowledged");
    client.configuration_done().expect("configuration done");
    let stopped = client.wait_for_stopped(Duration::from_secs(60));
    if case != "ambient" && case != "production" {
        assert!(
            stopped.is_ok(),
            "a delayed answer inside the test budget must succeed: {stopped:?}"
        );
    }
    let observed: Value = serde_json::from_str(&std::fs::read_to_string(&capture).expect("worker reached RunToEntry"))
        .expect("worker capture");
    assert_eq!(observed["query"], "RunToEntry");
    let expected = match case.as_str() {
        "default" => "60",
        "ambient" => "1",
        "explicit" => "20",
        "fractional" => "13",
        "production" => "invalid",
        _ => panic!("unknown case {case}"),
    };
    assert_eq!(
        observed["timeout"], expected,
        "the actual spawned worker's budget; launch result: {stopped:?}"
    );
    if case == "ambient" || case == "production" {
        let error = stopped
            .expect_err("the explicit one-second budget must still expire")
            .to_string();
        assert!(error.contains("timed out"), "{error}");
        assert!(error.contains("RunToEntry"), "{error}");
        assert!(error.contains("elapsed"), "{error}");
        assert!(error.contains("worker stable[0] pid Some("), "{error}");
        let budget = if case == "ambient" { "1s" } else { "10s" };
        assert!(error.contains(&format!("configured timeout Some({budget})")), "{error}");
    } else {
        stopped.unwrap_or_else(|error| panic!("a delayed answer inside the test budget must succeed: {error}"));
        let event = client
            .recv_event("ct/complete-move", Duration::from_secs(60))
            .expect("completed move");
        assert_eq!(event.body["location"]["path"], "/delayed-worker.c");
        assert_eq!(event.body["location"]["line"], 42);
        assert_eq!(event.body["location"]["functionName"], "delayed_entry");
    }
}
