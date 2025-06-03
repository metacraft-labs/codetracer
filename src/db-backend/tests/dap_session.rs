use db_backend::dap::{self, DapClient, DapMessage, Event, ProtocolMessage, Response};
use serde_json::json;
use std::io::BufReader;
use std::os::unix::net::UnixStream;
use std::thread;

fn run_server(stream: UnixStream) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut writer = stream;
    let mut seq = 1i64;
    loop {
        let msg = match dap::from_reader(&mut reader) {
            Ok(m) => m,
            Err(_) => break,
        };
        match msg {
            DapMessage::Request(req) if req.command == "initialize" => {
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage { seq, type_: "response".to_string() },
                    request_seq: req.base.seq,
                    success: true,
                    command: "initialize".to_string(),
                    message: None,
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(&mut writer, &resp).unwrap();
            }
            DapMessage::Request(req) if req.command == "launch" => {
                let event = DapMessage::Event(Event {
                    base: ProtocolMessage { seq, type_: "event".to_string() },
                    event: "initialized".to_string(),
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(&mut writer, &event).unwrap();
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage { seq, type_: "response".to_string() },
                    request_seq: req.base.seq,
                    success: true,
                    command: "launch".to_string(),
                    message: None,
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(&mut writer, &resp).unwrap();
            }
            _ => {}
        }
    }
}

#[test]
fn test_simple_session() {
    let (client_stream, server_stream) = UnixStream::pair().unwrap();
    let handle = thread::spawn(move || run_server(server_stream));

    let mut reader = BufReader::new(client_stream.try_clone().unwrap());
    let mut writer = client_stream;

    let mut client = DapClient::default();
    let init = client.request("initialize", json!({"adapterID":"small-lang"}));
    dap::write_message(&mut writer, &init).unwrap();

    let launch = client.request("launch", json!({"program":"main"}));
    dap::write_message(&mut writer, &launch).unwrap();

    let msg1 = dap::from_reader(&mut reader).unwrap();
    match msg1 {
        DapMessage::Response(resp) => assert_eq!(resp.command, "initialize"),
        _ => panic!("expected response"),
    }
    let msg2 = dap::from_reader(&mut reader).unwrap();
    match msg2 {
        DapMessage::Event(ev) => assert_eq!(ev.event, "initialized"),
        _ => panic!("expected event"),
    }
    let msg3 = dap::from_reader(&mut reader).unwrap();
    match msg3 {
        DapMessage::Response(resp) => assert_eq!(resp.command, "launch"),
        _ => panic!("expected response"),
    }

    drop(writer);
    drop(reader);
    handle.join().unwrap();
}
