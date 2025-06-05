use db_backend::dap::{
    self, Breakpoint, DapClient, DapMessage, Event, LaunchRequestArguments, ProtocolMessage, RequestArguments,
    Response, SetBreakpointsArguments, SetBreakpointsResponseBody, Source, SourceBreakpoint,
};
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
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
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
                    base: ProtocolMessage {
                        seq,
                        type_: "event".to_string(),
                    },
                    event: "initialized".to_string(),
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(&mut writer, &event).unwrap();
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
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

fn run_breakpoint_server(stream: UnixStream) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut writer = stream;
    let mut seq = 1i64;
    loop {
        let msg = match dap::from_reader(&mut reader) {
            Ok(m) => m,
            Err(_) => break,
        };
        match msg {
            DapMessage::Request(req) if req.command == "setBreakpoints" => {
                if let RequestArguments::SetBreakpoints(args) = req.arguments {
                    let lines: Vec<i64> = args
                        .breakpoints
                        .unwrap_or_default()
                        .into_iter()
                        .map(|b| b.line)
                        .collect();
                    let bps: Vec<Breakpoint> = lines
                        .into_iter()
                        .map(|l| Breakpoint {
                            id: None,
                            verified: true,
                            message: None,
                            source: args.source.clone().path.map(|p| Source {
                                name: None,
                                path: Some(p),
                                source_reference: None,
                            }),
                            line: Some(l),
                        })
                        .collect();
                    let body = SetBreakpointsResponseBody { breakpoints: bps };
                    let resp = DapMessage::Response(Response {
                        base: ProtocolMessage {
                            seq,
                            type_: "response".to_string(),
                        },
                        request_seq: req.base.seq,
                        success: true,
                        command: "setBreakpoints".to_string(),
                        message: None,
                        body: serde_json::to_value(body).unwrap(),
                    });
                    seq += 1;
                    dap::write_message(&mut writer, &resp).unwrap();
                }
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
    let init = client.request("initialize", RequestArguments::Other(json!({"adapterID":"small-lang"})));
    dap::write_message(&mut writer, &init).unwrap();

    let launch = client.launch(LaunchRequestArguments {
        program: Some("main".to_string()),
        trace_folder: None,
        pid: None,
        no_debug: None,
        restart: None,
    });
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

#[test]
fn test_set_breakpoints_roundtrip() {
    let (client_stream, server_stream) = UnixStream::pair().unwrap();
    let handle = thread::spawn(move || run_breakpoint_server(server_stream));

    let mut reader = BufReader::new(client_stream.try_clone().unwrap());
    let mut writer = client_stream;

    let mut client = DapClient::default();
    let args = SetBreakpointsArguments {
        source: Source {
            name: None,
            path: Some("file.rs".to_string()),
            source_reference: None,
        },
        breakpoints: Some(vec![
            SourceBreakpoint { line: 10, column: None },
            SourceBreakpoint { line: 20, column: None },
        ]),
        lines: None,
        source_modified: None,
    };
    let req = client.set_breakpoints(args);
    dap::write_message(&mut writer, &req).unwrap();

    let msg = dap::from_reader(&mut reader).unwrap();
    match msg {
        DapMessage::Response(resp) => {
            assert_eq!(resp.command, "setBreakpoints");
            let body: SetBreakpointsResponseBody = serde_json::from_value(resp.body).unwrap();
            assert_eq!(body.breakpoints.len(), 2);
            assert!(body.breakpoints.iter().all(|b| b.verified));
        }
        _ => panic!("expected response"),
    }

    drop(writer);
    drop(reader);
    handle.join().unwrap();
}
