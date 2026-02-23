use db_backend::dap::{self, DapClient, DapMessage};
use db_backend::transport::DapTransport;
use serde_json::json;
use std::io::BufReader;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

fn terminate_child(child: &mut Child) {
    for _ in 0..20 {
        match child.try_wait() {
            Ok(Some(_status)) => return,
            Ok(None) => thread::sleep(Duration::from_millis(50)),
            Err(_) => break,
        }
    }

    child.kill().ok();
    child.wait().ok();
}

fn wait_for_child_exit(child: &mut Child, timeout: Duration) -> Option<std::process::ExitStatus> {
    let poll_interval = Duration::from_millis(50);
    let polls = (timeout.as_millis() / poll_interval.as_millis()) as usize;
    for _ in 0..polls {
        match child.try_wait() {
            Ok(Some(status)) => return Some(status),
            Ok(None) => thread::sleep(poll_interval),
            Err(_) => return None,
        }
    }
    None
}

#[test]
fn dap_server_stdio_initialize_handshake_works() {
    let bin = env!("CARGO_BIN_EXE_db-backend");
    let mut child = Command::new(bin)
        .arg("dap-server")
        .arg("--stdio")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|err| panic!("failed to spawn db-backend: {err}"));

    let mut writer = child.stdin.take().expect("missing child stdin");
    let mut client = DapClient::default();

    let reader_stdout = child.stdout.take().expect("missing child stdout");
    let (tx, rx) = mpsc::channel::<Result<DapMessage, String>>();
    let reader_thread = thread::spawn(move || {
        let mut reader = BufReader::new(reader_stdout);
        loop {
            match dap::read_dap_message_from_reader(&mut reader) {
                Ok(msg) => {
                    if tx.send(Ok(msg)).is_err() {
                        break;
                    }
                }
                Err(err) => {
                    let _ = tx.send(Err(err.to_string()));
                    break;
                }
            }
        }
    });

    let init = client.request("initialize", json!({}));
    writer
        .send(&init)
        .unwrap_or_else(|err| panic!("failed to send initialize request: {err}"));

    let mut initialize_response_seen = false;
    let mut initialized_event_seen = false;
    for _ in 0..4 {
        let message = rx
            .recv_timeout(Duration::from_secs(3))
            .unwrap_or_else(|err| panic!("timed out waiting for stdio DAP handshake: {err}"))
            .unwrap_or_else(|err| panic!("failed while reading stdio DAP message: {err}"));
        match message {
            DapMessage::Response(r) if r.command == "initialize" => {
                initialize_response_seen = true;
                assert!(r.success, "initialize response reported failure");
                assert_eq!(
                    r.body["supportsConfigurationDoneRequest"].as_bool(),
                    Some(true),
                    "initialize response missing expected capability"
                );
            }
            DapMessage::Event(e) if e.event == "initialized" => {
                initialized_event_seen = true;
            }
            _ => {}
        }
        if initialize_response_seen && initialized_event_seen {
            break;
        }
    }

    assert!(
        initialize_response_seen,
        "did not observe initialize response over stdio"
    );
    assert!(initialized_event_seen, "did not observe initialized event over stdio");

    drop(writer);
    terminate_child(&mut child);
    reader_thread
        .join()
        .unwrap_or_else(|_| panic!("stdio reader thread panicked"));
}

#[test]
fn dap_server_stdio_disconnect_acknowledges_and_exits() {
    let bin = env!("CARGO_BIN_EXE_db-backend");
    let mut child = Command::new(bin)
        .arg("dap-server")
        .arg("--stdio")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|err| panic!("failed to spawn db-backend: {err}"));

    let mut writer = child.stdin.take().expect("missing child stdin");
    let mut client = DapClient::default();

    let reader_stdout = child.stdout.take().expect("missing child stdout");
    let (tx, rx) = mpsc::channel::<Result<DapMessage, String>>();
    let reader_thread = thread::spawn(move || {
        let mut reader = BufReader::new(reader_stdout);
        loop {
            match dap::read_dap_message_from_reader(&mut reader) {
                Ok(msg) => {
                    if tx.send(Ok(msg)).is_err() {
                        break;
                    }
                }
                Err(err) => {
                    let _ = tx.send(Err(err.to_string()));
                    break;
                }
            }
        }
    });

    let init = client.request("initialize", json!({}));
    writer
        .send(&init)
        .unwrap_or_else(|err| panic!("failed to send initialize request: {err}"));

    let mut initialize_response_seen = false;
    let mut initialized_event_seen = false;
    for _ in 0..4 {
        let message = rx
            .recv_timeout(Duration::from_secs(3))
            .unwrap_or_else(|err| panic!("timed out waiting for stdio initialize handshake: {err}"))
            .unwrap_or_else(|err| panic!("failed while reading stdio DAP message: {err}"));
        match message {
            DapMessage::Response(r) if r.command == "initialize" => {
                initialize_response_seen = true;
                assert!(r.success, "initialize response reported failure");
            }
            DapMessage::Event(e) if e.event == "initialized" => {
                initialized_event_seen = true;
            }
            _ => {}
        }
        if initialize_response_seen && initialized_event_seen {
            break;
        }
    }
    assert!(
        initialize_response_seen && initialized_event_seen,
        "did not observe initialize handshake before disconnect"
    );

    let disconnect = client.request("disconnect", json!({}));
    writer
        .send(&disconnect)
        .unwrap_or_else(|err| panic!("failed to send disconnect request: {err}"));

    let message = rx
        .recv_timeout(Duration::from_secs(3))
        .unwrap_or_else(|err| panic!("timed out waiting for disconnect response: {err}"))
        .unwrap_or_else(|err| panic!("failed while reading stdio DAP message: {err}"));
    match message {
        DapMessage::Response(r) => {
            assert_eq!(r.command, "disconnect");
            assert!(r.success, "disconnect response reported failure");
        }
        other => panic!("expected disconnect response, got {other:?}"),
    }

    let status = wait_for_child_exit(&mut child, Duration::from_secs(3))
        .unwrap_or_else(|| panic!("db-backend did not exit after disconnect response"));
    assert!(status.success(), "db-backend exited unsuccessfully: {status}");

    drop(writer);
    terminate_child(&mut child);
    reader_thread
        .join()
        .unwrap_or_else(|_| panic!("stdio reader thread panicked"));
}
