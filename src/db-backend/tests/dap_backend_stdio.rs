use db_backend::dap::{self, DapClient, DapMessage, LaunchRequestArguments, RequestArguments};
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
        .arg("--stdio")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();

    let mut writer = child.stdin.take().unwrap();
    let mut reader = BufReader::new(child.stdout.take().unwrap());

    let mut client = DapClient::default();
    let init = client.request("initialize", RequestArguments::Other(json!({})));
    dap::write_message(&mut writer, &init).unwrap();
    let launch_args = LaunchRequestArguments {
        program: Some("main".to_string()),
        trace_folder: Some(trace_dir),
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

    drop(writer);
    drop(reader);
    let _ = child.wait().unwrap();
}
