use db_backend::dap::{self, DapClient, DapMessage, LaunchRequestArguments};
use db_backend::dap_types::StackTraceArguments;
use db_backend::transport::DapTransport;
use serde_json::json;
use std::io::BufReader;
use std::path::PathBuf;
use std::process::{Command, Stdio};

#[test]
fn test_backend_dap_server_stdio() {
    let bin = env!("CARGO_BIN_EXE_db-backend");
    let pid = std::process::id() as usize;
    let trace_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("trace");

    let mut child = Command::new(bin)
        .arg("dap-server")
        .arg("--stdio")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();

    let mut writer = child.stdin.take().unwrap();
    let mut reader = BufReader::new(child.stdout.take().unwrap());

    let mut client = DapClient::default();
    let init = client.request("initialize", json!({}));
    // dap::write_message(&mut writer, &init).unwrap();

    writer
        .send(&init)
        .unwrap_or_else(|err| panic!("failed to send initialize request: {err}"));

    let launch_args = LaunchRequestArguments {
        program: Some("main".to_string()),
        trace_folder: Some(trace_dir),
        trace_file: None,
        raw_diff_index: None,
        pid: Some(pid as u64),
        cwd: None,
        no_debug: None,
        restart: None,
        name: None,
        request: None,
        typ: None,
        session_id: None,
    };
    let launch = client.launch(launch_args).unwrap();
    // dap::write_message(&mut writer, &launch).unwrap();
    writer
        .send(&launch)
        .unwrap_or_else(|err| panic!("failed to send launch request: {err}"));

    let msg1 = dap::read_dap_message_from_reader(&mut reader)
        .unwrap_or_else(|err| panic!("failed to read initialize response: {err}"));
    match msg1 {
        DapMessage::Response(r) => {
            assert_eq!(r.command, "initialize");
            // assert!(r.body["supportsLoadedSourcesRequest"].as_bool().unwrap());
            assert!(r.body["supportsStepBack"].as_bool().unwrap());
            assert!(r.body["supportsConfigurationDoneRequest"].as_bool().unwrap());
            assert!(r.body["supportsDisassembleRequest"].as_bool().unwrap());
            assert!(r.body["supportsLogPoints"].as_bool().unwrap());
            assert!(r.body["supportsRestartRequest"].as_bool().unwrap());
        }
        _ => panic!(),
    }
    let msg2 = dap::read_dap_message_from_reader(&mut reader)
        .unwrap_or_else(|err| panic!("failed to read initialized event: {err}"));
    match msg2 {
        DapMessage::Event(e) => assert_eq!(e.event, "initialized"),
        _ => panic!(),
    }
    let conf_done = client.request("configurationDone", json!({}));
    // dap::write_message(&mut writer, &conf_done).unwrap();
    writer
        .send(&conf_done)
        .unwrap_or_else(|err| panic!("failed to send configurationDone request: {err}"));
    let msg3 = dap::read_dap_message_from_reader(&mut reader)
        .unwrap_or_else(|err| panic!("failed to read launch response: {err}"));
    match msg3 {
        DapMessage::Response(r) => assert_eq!(r.command, "launch"),
        _ => panic!(),
    }
    let msg4 = dap::read_dap_message_from_reader(&mut reader)
        .unwrap_or_else(|err| panic!("failed to read configurationDone response: {err}"));
    match msg4 {
        DapMessage::Response(r) => assert_eq!(r.command, "configurationDone"),
        _ => panic!(),
    }

    let msg5 = dap::read_dap_message_from_reader(&mut reader)
        .unwrap_or_else(|err| panic!("failed to read stopped event: {err}"));
    match msg5 {
        DapMessage::Event(e) => {
            assert_eq!(e.event, "stopped");
            assert_eq!(e.body["reason"], "entry");
        }
        _ => panic!("expected a stopped event, but got {:?}", msg5),
    }

    let msg_complete_move = dap::read_dap_message_from_reader(&mut reader)
        .unwrap_or_else(|err| panic!("failed to read ct/complete-move event: {err}"));
    match msg_complete_move {
        DapMessage::Event(e) => {
            assert_eq!(e.event, "ct/complete-move");
        }
        _ => panic!("expected a complete move events, but got {:?}", msg_complete_move),
    }

    let threads_request = client.request("threads", json!({}));
    // dap::write_message(&mut writer, &threads_request).unwrap();
    writer
        .send(&threads_request)
        .unwrap_or_else(|err| panic!("failed to send threads request: {err}"));
    let msg_threads = dap::read_dap_message_from_reader(&mut reader)
        .unwrap_or_else(|err| panic!("failed to read threads response: {err}"));
    match msg_threads {
        DapMessage::Response(r) => {
            assert_eq!(r.command, "threads");
            assert_eq!(r.body["threads"][0]["id"], 1);
        }
        _ => panic!(
            "expected a Response DapMessage after a threads request, but got {:?}",
            msg_threads
        ),
    }

    let stack_trace_request = client.request(
        "stackTrace",
        serde_json::to_value(StackTraceArguments {
            thread_id: 1,
            format: None,
            levels: None,
            start_frame: None,
        })
        .unwrap(),
    );
    // dap::write_message(&mut writer, &stack_trace_request).unwrap();
    writer
        .send(&stack_trace_request)
        .unwrap_or_else(|err| panic!("failed to send stackTrace request: {err}"));
    let msg_stack_trace = dap::read_dap_message_from_reader(&mut reader)
        .unwrap_or_else(|err| panic!("failed to read stackTrace response: {err}"));
    match msg_stack_trace {
        DapMessage::Response(r) => assert_eq!(r.command, "stackTrace"), // TODO: test stackFrames / totalFrames ?
        _ => panic!(),
    }

    drop(writer);
    drop(reader);
    let _ = child.wait().unwrap();
}
