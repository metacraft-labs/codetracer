use std::io::BufReader;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde_json::json;

use db_backend::dap::{self, DapClient, DapMessage, LaunchRequestArguments};
// use db_backend::dap_types::StackTraceArguments;
use db_backend::task;

#[test]
#[ignore] // ignored by default, as they depend on closed source ct-rr-worker/also not finished setup
fn test_rr() {
    let bin = env!("CARGO_BIN_EXE_db-backend");
    let pid = std::process::id() as usize;
    let trace_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("rr-trace");

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
    dap::write_message(&mut writer, &init).unwrap();
    let launch_args = LaunchRequestArguments {
        program: Some("rr_gdb".to_string()),
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
        ct_rr_worker_exe: Some(PathBuf::from("/home/alexander92/codetracer-rr-backend/src/build-debug/bin/ct-rr-worker")),
    };
    let launch = client.launch(launch_args).unwrap();
    dap::write_message(&mut writer, &launch).unwrap();

    let msg1 = dap::from_reader(&mut reader).unwrap();
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
    let msg2 = dap::from_reader(&mut reader).unwrap();
    match msg2 {
        DapMessage::Event(e) => assert_eq!(e.event, "initialized"),
        _ => panic!(),
    }
    let conf_done = client.request("configurationDone", json!({}));
    dap::write_message(&mut writer, &conf_done).unwrap();
    let msg3 = dap::from_reader(&mut reader).unwrap();
    match msg3 {
        DapMessage::Response(r) => assert_eq!(r.command, "launch"),
        _ => panic!(),
    }
    let msg4 = dap::from_reader(&mut reader).unwrap();
    match msg4 {
        DapMessage::Response(r) => assert_eq!(r.command, "configurationDone"),
        _ => panic!(),
    }

    let msg5 = dap::from_reader(&mut reader).unwrap();
    match msg5 {
        DapMessage::Event(e) => {
            assert_eq!(e.event, "stopped");
            assert_eq!(e.body["reason"], "entry");
        }
        _ => panic!("expected a stopped event, but got {:?}", msg5),
    }

    let msg_complete_move = dap::from_reader(&mut reader).unwrap();
    match msg_complete_move {
        DapMessage::Event(e) => {
            assert_eq!(e.event, "ct/complete-move");
            let move_state = serde_json::from_value::<task::MoveState>(e.body).expect("valid move state");
            let path = PathBuf::from(move_state.clone().location.path);
            let filename = path.file_name().expect("filename");
            assert_eq!(filename.display().to_string(), "rr_gdb.rs");
            assert_eq!(move_state.location.line, 205);
            assert_eq!(move_state.location.function_name.starts_with("rr_gdb::main"), true);
            
        }
        _ => panic!("expected a complete move events, but got {:?}", msg_complete_move),
    }

    // next to next line in `main`
    let next_request = client.request("next", json!({}));
    dap::write_message(&mut writer, &next_request).unwrap();

    // `stepIn` to `run` 
    let step_in_request = client.request("stepIn", json!({}));
    dap::write_message(&mut writer, &step_in_request).unwrap();

    // `next` to next line in `run`: to check a local
    dap::write_message(&mut writer, &next_request).unwrap();

    for _ in 0 .. 7 {
        let _ = dap::from_reader(&mut reader).unwrap();
    }

    let msg_complete_move_before_local_check = dap::from_reader(&mut reader).unwrap();
    match msg_complete_move_before_local_check {
        DapMessage::Event(e) => {
            assert_eq!(e.event, "ct/complete-move");
            let move_state = serde_json::from_value::<task::MoveState>(e.body).expect("valid move state");
            let path = PathBuf::from(move_state.clone().location.path);
            let filename = path.file_name().expect("filename");
            assert_eq!(filename.display().to_string(), "rr_gdb.rs");
            assert_eq!(move_state.location.line, 72);
            assert_eq!(move_state.location.function_name.starts_with("rr_gdb::run"), true);
        }
        _ => panic!("expected a complete move events, but got {:?}", msg_complete_move_before_local_check),

    }

    let load_locals_request = client.request("ct/load-locals", serde_json::to_value(&task::CtLoadLocalsArguments {
        count_budget: 3_000,
        min_count_limit: 50,
        rr_ticks: 0,
    }).unwrap());
    let _next_response = dap::from_reader(&mut reader).unwrap();

    dap::write_message(&mut writer, &load_locals_request).unwrap();
    let load_locals_response = dap::from_reader(&mut reader).unwrap();
    if let DapMessage::Response(response) = load_locals_response {
        assert_eq!(response.command, "ct/load-locals");
        println!("{:?}", response.body);
        let variables = serde_json::from_value::<task::CtLoadLocalsResponseBody>(response.body)
            .expect("valid local response")
            .locals;
        assert_eq!(variables[0].expression, "i");
        assert_eq!(variables[0].value.typ.lang_type, "i64"); //?
        assert_eq!(variables[0].value.i, "0");
    }

    // let threads_request = client.request("threads", json!({}));
    // dap::write_message(&mut writer, &threads_request).unwrap();
    // let msg_threads = dap::from_reader(&mut reader).unwrap();
    // match msg_threads {
    //     DapMessage::Response(r) => {
    //         assert_eq!(r.command, "threads");
    //         assert_eq!(r.body["threads"][0]["id"], 1);
    //     }
    //     _ => panic!(
    //         "expected a Response DapMessage after a threads request, but got {:?}",
    //         msg_threads
    //     ),
    // }

    // let stack_trace_request = client.request(
    //     "stackTrace",
    //     serde_json::to_value(StackTraceArguments {
    //         thread_id: 1,
    //         format: None,
    //         levels: None,
    //         start_frame: None,
    //     })
    //     .unwrap(),
    // );
    // dap::write_message(&mut writer, &stack_trace_request).unwrap();
    // let msg_stack_trace = dap::from_reader(&mut reader).unwrap();
    // match msg_stack_trace {
    //     DapMessage::Response(r) => assert_eq!(r.command, "stackTrace"), // TODO: test stackFrames / totalFrames ?
    //     _ => panic!(),
    // }

    drop(writer);
    drop(reader);
    let _ = child.wait().unwrap();
}
