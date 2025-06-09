use db_backend::dap::{
    self, Breakpoint, Capabilities, DapClient, DapMessage, Event, LaunchRequestArguments, ProtocolMessage,
    RequestArguments, Response, SetBreakpointsArguments, SetBreakpointsResponseBody, Source, SourceBreakpoint,
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
                let capabilities = Capabilities {
                    supports_loaded_sources_request: Some(true),
                    supports_step_back: Some(true),
                    supports_configuration_done_request: Some(true),
                    supports_disassemble_request: Some(true),
                    supports_log_points: Some(true),
                    supports_restart_request: Some(true),
                };
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
                    request_seq: req.base.seq,
                    success: true,
                    command: "initialize".to_string(),
                    message: None,
                    body: serde_json::to_value(capabilities).unwrap(),
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
            DapMessage::Request(req) if req.command == "configurationDone" => {
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
                    request_seq: req.base.seq,
                    success: true,
                    command: "configurationDone".to_string(),
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

fn sample_db() -> db_backend::db::Db {
    use db_backend::db::Db;
    use db_backend::trace_processor::TraceProcessor;
    use runtime_tracing::{
        CallRecord, FunctionId, FunctionRecord, Line, PathId, StepRecord, TraceLowLevelEvent, TraceMetadata, TypeId,
        TypeKind, TypeRecord, TypeSpecificInfo,
    };
    use std::path::PathBuf;

    let none_type = TypeRecord {
        kind: TypeKind::None,
        lang_type: "None".to_string(),
        specific_info: TypeSpecificInfo::None,
    };
    let struct_type = TypeRecord {
        kind: TypeKind::Struct,
        lang_type: "ExampleStruct".to_string(),
        specific_info: TypeSpecificInfo::Struct {
            fields: vec![runtime_tracing::FieldTypeRecord {
                name: "a".to_string(),
                type_id: TypeId(0),
            }],
        },
    };

    let trace: Vec<TraceLowLevelEvent> = vec![
        TraceLowLevelEvent::Path(PathBuf::from("/test/workdir")),
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "<top-level>".to_string(),
        }),
        TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(0),
            args: vec![],
        }),
        TraceLowLevelEvent::Type(none_type),
        TraceLowLevelEvent::Type(struct_type),
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(1),
        }),
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(2),
        }),
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(3),
        }),
    ];
    let trace_metadata = TraceMetadata {
        workdir: PathBuf::from("/test/workdir"),
        program: "test".to_string(),
        args: vec![],
    };
    let mut db = Db::new(&trace_metadata.workdir);
    let mut trace_processor = TraceProcessor::new(&mut db);
    trace_processor.postprocess(&trace).unwrap();
    db
}

fn run_step_server(stream: UnixStream) {
    use db_backend::handler::Handler;
    use db_backend::task::{gen_task_id, Action, StepArg, Task, TaskKind};
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut writer = stream;
    let mut seq = 1i64;
    let (tx, _rx) = std::sync::mpsc::channel();
    let mut handler = Handler::new(Box::new(sample_db()), tx);
    loop {
        let msg = match dap::from_reader(&mut reader) {
            Ok(m) => m,
            Err(_) => break,
        };
        match msg {
            DapMessage::Request(req) if req.command == "stepIn" => {
                handler
                    .step(
                        StepArg::new(Action::StepIn),
                        Task {
                            kind: TaskKind::Step,
                            id: gen_task_id(TaskKind::Step),
                        },
                    )
                    .unwrap();
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
                    request_seq: req.base.seq,
                    success: true,
                    command: "stepIn".to_string(),
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
        DapMessage::Response(resp) => {
            assert_eq!(resp.command, "initialize");
            assert!(resp.body["supportsLoadedSourcesRequest"].as_bool().unwrap());
            assert!(resp.body["supportsStepBack"].as_bool().unwrap());
            assert!(resp.body["supportsConfigurationDoneRequest"].as_bool().unwrap());
            assert!(resp.body["supportsDisassembleRequest"].as_bool().unwrap());
            assert!(resp.body["supportsLogPoints"].as_bool().unwrap());
            assert!(resp.body["supportsRestartRequest"].as_bool().unwrap());
        }
        _ => panic!("expected response"),
    }
    let msg2 = dap::from_reader(&mut reader).unwrap();
    match msg2 {
        DapMessage::Event(ev) => assert_eq!(ev.event, "initialized"),
        _ => panic!("expected event"),
    }
    let conf_done = client.request("configurationDone", RequestArguments::Other(json!({})));
    dap::write_message(&mut writer, &conf_done).unwrap();
    let msg3 = dap::from_reader(&mut reader).unwrap();
    match msg3 {
        DapMessage::Response(resp) => assert_eq!(resp.command, "launch"),
        _ => panic!("expected response"),
    }
    let msg4 = dap::from_reader(&mut reader).unwrap();
    match msg4 {
        DapMessage::Response(resp) => assert_eq!(resp.command, "configurationDone"),
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

#[test]
fn test_step_in_roundtrip() {
    let (client_stream, server_stream) = UnixStream::pair().unwrap();
    let handle = thread::spawn(move || run_step_server(server_stream));

    let mut reader = BufReader::new(client_stream.try_clone().unwrap());
    let mut writer = client_stream;

    let mut client = DapClient::default();
    let req = client.request("stepIn", RequestArguments::Other(json!({})));
    dap::write_message(&mut writer, &req).unwrap();

    let msg = dap::from_reader(&mut reader).unwrap();
    match msg {
        DapMessage::Response(resp) => {
            assert_eq!(resp.command, "stepIn");
        }
        _ => panic!("expected response"),
    }

    drop(writer);
    drop(reader);
    handle.join().unwrap();
}
