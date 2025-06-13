use db_backend::dap::{self, DapClient, DapMessage, LaunchRequestArguments, RequestArguments};
use db_backend::dap_server::{self};
use serde_json::json;
use std::io::BufReader;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;

fn wait_for_socket(path: &Path) {
    for _ in 0..50 {
        if path.exists() {
            return;
        }
        thread::sleep(Duration::from_millis(100));
    }
    // println!("{path:?}");
    panic!("socket not created");
}

#[test]
fn test_backend_dap_server() {
    let bin = env!("CARGO_BIN_EXE_db-backend");
    let pid = std::process::id() as usize;
    let trace_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("trace");

    let socket_path = dap_server::socket_path_for(std::process::id() as usize);
    let mut child = Command::new(bin).arg(&socket_path).spawn().unwrap();
    wait_for_socket(&socket_path);

    let stream = UnixStream::connect(&socket_path).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut writer = stream;

    let mut client = DapClient::default();
    let init = client.request("initialize", RequestArguments::Other(json!({})));
    dap::write_message(&mut writer, &init).unwrap();
    let launch_args = LaunchRequestArguments {
        program: Some("main".to_string()),
        trace_folder: Some(trace_dir),
        trace_file: None,
        pid: Some(pid as u64),
        cwd: None,
        no_debug: None,
        restart: None,
    };
    let launch = client.launch(launch_args);
    dap::write_message(&mut writer, &launch).unwrap();

    let msg1 = dap::from_reader(&mut reader).unwrap();
    match msg1 {
        DapMessage::Response(r) => {
            assert_eq!(r.command, "initialize");
            assert!(r.body["supportsLoadedSourcesRequest"].as_bool().unwrap());
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
    let conf_done = client.request("configurationDone", RequestArguments::Other(json!({})));
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
        _ => panic!(),
    }
    let threads_request = client.request("threads", RequestArguments::Other(json!({})));
    dap::write_message(&mut writer, &threads_request).unwrap();
    let msg_threads = dap::from_reader(&mut reader).unwrap();
    match msg_threads {
        DapMessage::Response(r) => assert_eq!(r.command, "threads"),
        _ => panic!(),
    }

    drop(writer);
    drop(reader);
    let _ = child.wait().unwrap();
}
