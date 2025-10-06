use db_backend::dap::{self, DapClient, DapMessage, LaunchRequestArguments};
use db_backend::dap_server;
use db_backend::dap_types::StackTraceArguments;
use db_backend::transport::DapTransport;
use serde_json::json;
use std::io::{BufReader, ErrorKind};

use std::os::unix::net::{UnixListener, UnixStream};

use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};
use std::{fs, thread};

fn accept_with_timeout(
    listener: &UnixListener,
    timeout: Duration,
) -> std::io::Result<(UnixStream, std::os::unix::net::SocketAddr)> {
    listener.set_nonblocking(true)?;
    let start = Instant::now();
    loop {
        match listener.accept() {
            Ok(pair) => return Ok(pair),
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if start.elapsed() >= timeout {
                    return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "accept timeout"));
                }
                thread::sleep(Duration::from_millis(20));
            }
            Err(e) => return Err(e),
        }
    }
}

#[test]
fn test_backend_dap_server() {
    let bin = env!("CARGO_BIN_EXE_db-backend");
    let pid = std::process::id() as usize;
    let trace_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("trace");

    let socket_path = dap_server::socket_path_for(std::process::id() as usize);

    if let Some(dir) = socket_path.parent() {
        fs::create_dir_all(dir).unwrap_or_else(|err| panic!("failed to create socket directory {dir:?}: {err}"));
    }

    if socket_path.exists() {
        fs::remove_file(&socket_path)
            .unwrap_or_else(|err| panic!("failed to remove pre-existing socket {socket_path:?}: {err}"));
    }

    let listener = match UnixListener::bind(&socket_path) {
        Ok(listener) => listener,
        Err(err) if err.kind() == ErrorKind::PermissionDenied => {
            eprintln!("skipping test: sandbox denied binding to debug adapter socket {socket_path:?}: {err}");
            return;
        }
        Err(err) => panic!("failed to bind to socket {socket_path:?}: {err}"),
    };

    // (optional) tighten perms if you want:
    // use std::os::unix::fs::PermissionsExt;
    // fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600))?;

    let mut child = Command::new(bin).arg("dap-server").arg(&socket_path).spawn().unwrap();
    println!("Bin: {}", bin);

    println!("Socket path: {}", socket_path.to_str().unwrap());
    let (stream, _addr) = accept_with_timeout(&listener, Duration::from_secs(5)).unwrap();

    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut writer = stream;

    let mut client = DapClient::default();
    let init = client.request("initialize", json!({}));
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
        ct_rr_worker_exe: None,
    };

    let launch = client.launch(launch_args).expect("failed to build launch request");
    writer
        .send(&launch)
        .unwrap_or_else(|err| panic!("failed to send launch request: {err}"));

    // let mut buf = String::new();
    // let x = reader.read_to_string(&mut buf).unwrap();
    // println!("Read: {}", x);

    let msg1 = dap::read_dap_message_from_reader(&mut reader)
        .unwrap_or_else(|err| panic!("failed to read initialize response: {err}"));
    match msg1 {
        DapMessage::Response(r) => {
            assert_eq!(r.command, "initialize");
            println!("{:?}", r.body);
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
    writer.send(&conf_done).unwrap();
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
    writer.send(&threads_request).unwrap();
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
    writer.send(&stack_trace_request).unwrap();
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
