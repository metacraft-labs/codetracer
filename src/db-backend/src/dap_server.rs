use crate::dap::{
    self, Breakpoint, DapMessage, Event, ProtocolMessage, RequestArguments, Response, SetBreakpointsResponseBody,
    Source,
};
use crate::db::Db;
use crate::handler::Handler;
use crate::task::{gen_task_id, Action, SourceLocation, StepArg, Task, TaskId, TaskKind};
use crate::trace_processor::{load_trace_data, load_trace_metadata, TraceProcessor};
use log::info;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::mpsc;

pub const DAP_SOCKET_PATH: &str = "/tmp/ct_dap_socket";

pub fn socket_path_for(pid: usize) -> PathBuf {
    PathBuf::from(format!("{DAP_SOCKET_PATH}_{}", pid))
}

pub fn run(socket_path: &Path) -> Result<(), Box<dyn Error>> {
    let _ = std::fs::remove_file(socket_path);
    let listener = UnixListener::bind(socket_path)?;
    let (stream, _) = listener.accept()?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = stream;
    handle_client(&mut reader, &mut writer)
}

pub fn run_stdio() -> Result<(), Box<dyn Error>> {
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut writer = stdout.lock();
    handle_client(&mut reader, &mut writer)
}

fn launch(trace_folder: &Path, tx: mpsc::Sender<crate::response::Response>) -> Result<Handler, Box<dyn Error>> {
    info!("run launch() for {:?}", trace_folder);
    let metadata_path = trace_folder.join("trace_metadata.json");
    let trace_path = trace_folder.join("trace.json");
    if let (Ok(meta), Ok(trace)) = (load_trace_metadata(&metadata_path), load_trace_data(&trace_path)) {
        let mut db = Db::new(&meta.workdir);
        let mut proc = TraceProcessor::new(&mut db);
        proc.postprocess(&trace)?;
        eprintln!("TRACE METADATA: {:?}", meta);
        let mut handler = Handler::new(Box::new(db), tx.clone());
        handler.run_to_entry(Task {
            kind: TaskKind::RunToEntry,
            id: TaskId("run-to-entry-0".to_string()),
        })?;
        Ok(handler)
    } else {
        Err("problem with reading metadata or path trace files".into())
    }
}

fn handle_client<R: BufRead, W: Write>(reader: &mut R, writer: &mut W) -> Result<(), Box<dyn Error>> {
    let mut seq = 1i64;
    let mut breakpoints: HashMap<String, HashSet<i64>> = HashMap::new();
    let (tx, _rx) = mpsc::channel();
    let mut handler: Option<Handler> = None;
    let mut received_launch = false;
    let mut launch_trace_folder = PathBuf::from("");
    let mut received_configuration_done = false;
    while let Ok(msg) = dap::from_reader(reader) {
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
                dap::write_message(writer, &resp)?;

                let event = DapMessage::Event(Event {
                    base: ProtocolMessage {
                        seq,
                        type_: "event".to_string(),
                    },
                    event: "initialized".to_string(),
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(writer, &event)?;
            }
            DapMessage::Request(req) if req.command == "setBreakpoints" => {
                let mut results = Vec::new();
                if let RequestArguments::SetBreakpoints(args) = req.arguments {
                    if let Some(path) = args.source.path.clone() {
                        let lines: Vec<i64> = if let Some(bps) = args.breakpoints {
                            bps.into_iter().map(|b| b.line).collect()
                        } else {
                            args.lines.unwrap_or_default()
                        };
                        let entry = breakpoints.entry(path.clone()).or_default();
                        for line in lines {
                            entry.insert(line);
                            if let Some(h) = handler.as_mut() {
                                let _ = h.add_breakpoint(
                                    SourceLocation {
                                        path: path.clone(),
                                        line: line as usize,
                                    },
                                    Task {
                                        kind: TaskKind::AddBreak,
                                        id: gen_task_id(TaskKind::AddBreak),
                                    },
                                );
                            }
                            results.push(Breakpoint {
                                id: None,
                                verified: true,
                                message: None,
                                source: Some(Source {
                                    name: args.source.name.clone(),
                                    path: Some(path.clone()),
                                    source_reference: args.source.source_reference,
                                }),
                                line: Some(line),
                            });
                        }
                    } else {
                        let lines = args
                            .breakpoints
                            .unwrap_or_default()
                            .into_iter()
                            .map(|b| b.line)
                            .collect::<Vec<_>>();
                        for line in lines {
                            results.push(Breakpoint {
                                id: None,
                                verified: false,
                                message: Some("missing source path".to_string()),
                                source: None,
                                line: Some(line),
                            });
                        }
                    }
                }
                let body = SetBreakpointsResponseBody { breakpoints: results };
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
                    request_seq: req.base.seq,
                    success: true,
                    command: "setBreakpoints".to_string(),
                    message: None,
                    body: serde_json::to_value(body)?,
                });
                seq += 1;
                dap::write_message(writer, &resp)?;
            }
            DapMessage::Request(req) if req.command == "launch" => {
                received_launch = true;
                if let RequestArguments::Launch(args) = &req.arguments {
                    if let Some(folder) = &args.trace_folder {
                        launch_trace_folder = folder.clone();
                        info!("stored launch trace folder: {launch_trace_folder:?}");
                        if received_configuration_done {
                            handler = Some(launch(&launch_trace_folder, tx.clone())?);
                        }
                        if let Some(pid) = args.pid {
                            eprintln!("PID: {}", pid);
                        }
                    }
                }
                info!("received launch; configuration done? {received_configuration_done}; req: {req:?}");
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
                dap::write_message(writer, &resp)?;
            }
            DapMessage::Request(req) if req.command == "configurationDone" => {
                // TODO: run to entry/continue here, after setting the `launch` field
                received_configuration_done = true;
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
                dap::write_message(writer, &resp)?;

                info!("configuration done sent response; received_launch: {received_launch}");
                if received_launch {
                    handler = Some(launch(&launch_trace_folder, tx.clone())?);
                }
            }
            DapMessage::Request(req) if req.command == "stepIn" => {
                if let Some(h) = handler.as_mut() {
                    let _ = h.step(
                        StepArg::new(Action::StepIn),
                        Task {
                            kind: TaskKind::Step,
                            id: gen_task_id(TaskKind::Step),
                        },
                    );
                }
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
                dap::write_message(writer, &resp)?;
            }
            DapMessage::Request(req) if req.command == "next" => {
                if let Some(h) = handler.as_mut() {
                    let _ = h.step(
                        StepArg::new(Action::Next),
                        Task {
                            kind: TaskKind::Step,
                            id: gen_task_id(TaskKind::Step),
                        },
                    );
                }
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
                    request_seq: req.base.seq,
                    success: true,
                    command: "next".to_string(),
                    message: None,
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(writer, &resp)?;
            }
            DapMessage::Request(req) if req.command == "stepOut" => {
                if let Some(h) = handler.as_mut() {
                    let _ = h.step(
                        StepArg::new(Action::StepOut),
                        Task {
                            kind: TaskKind::Step,
                            id: gen_task_id(TaskKind::Step),
                        },
                    );
                }
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
                    request_seq: req.base.seq,
                    success: true,
                    command: "stepOut".to_string(),
                    message: None,
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(writer, &resp)?;
            }
            DapMessage::Request(req) if req.command == "continue" => {
                if let Some(h) = handler.as_mut() {
                    let _ = h.step(
                        StepArg::new(Action::Continue),
                        Task {
                            kind: TaskKind::Step,
                            id: gen_task_id(TaskKind::Step),
                        },
                    );
                }
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
                    request_seq: req.base.seq,
                    success: true,
                    command: "continue".to_string(),
                    message: None,
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(writer, &resp)?;
            }
            DapMessage::Request(req) if req.command == "reverseContinue" => {
                if let Some(h) = handler.as_mut() {
                    let mut arg = StepArg::new(Action::Continue);
                    arg.reverse = true;
                    let _ = h.step(
                        arg,
                        Task {
                            kind: TaskKind::Step,
                            id: gen_task_id(TaskKind::Step),
                        },
                    );
                }
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
                    request_seq: req.base.seq,
                    success: true,
                    command: "reverseContinue".to_string(),
                    message: None,
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(writer, &resp)?;
            }
            DapMessage::Request(req) if req.command == "stepBack" => {
                if let Some(h) = handler.as_mut() {
                    let mut arg = StepArg::new(Action::Next);
                    arg.reverse = true;
                    let _ = h.step(
                        arg,
                        Task {
                            kind: TaskKind::Step,
                            id: gen_task_id(TaskKind::Step),
                        },
                    );
                }
                let resp = DapMessage::Response(Response {
                    base: ProtocolMessage {
                        seq,
                        type_: "response".to_string(),
                    },
                    request_seq: req.base.seq,
                    success: true,
                    command: "stepBack".to_string(),
                    message: None,
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(writer, &resp)?;
            }
            _ => {}
        }
    }
    Ok(())
}
