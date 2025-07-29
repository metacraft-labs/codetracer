use crate::dap::{
    self, Breakpoint, DapMessage, Event, ProtocolMessage, RequestArguments, Response, SetBreakpointsResponseBody,
    Source,
};
use crate::trace_processor::load_trace_metadata;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::io::BufReader;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

pub const DAP_SOCKET_PATH: &str = "/tmp/ct_dap_socket";

pub fn socket_path_for(pid: usize) -> PathBuf {
    PathBuf::from(format!("{DAP_SOCKET_PATH}_{}", pid))
}

pub fn run(socket_path: &Path) -> Result<(), Box<dyn Error>> {
    let _ = std::fs::remove_file(socket_path);
    let listener = UnixListener::bind(socket_path)?;
    let (stream, _) = listener.accept()?;
    handle_client(stream)
}

fn handle_client(stream: UnixStream) -> Result<(), Box<dyn Error>> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = stream;
    let mut seq = 1i64;
    let mut breakpoints: HashMap<String, HashSet<i64>> = HashMap::new();
    while let Ok(msg) = dap::from_reader(&mut reader) {
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
                dap::write_message(&mut writer, &resp)?;
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
                dap::write_message(&mut writer, &resp)?;
            }
            DapMessage::Request(req) if req.command == "launch" => {
                if let RequestArguments::Launch(args) = &req.arguments {
                    if let Some(folder) = &args.trace_folder {
                        let metadata_path = folder.join("trace_metadata.json");
                        match load_trace_metadata(&metadata_path) {
                            Ok(meta) => println!("TRACE METADATA: {:?}", meta),
                            Err(e) => eprintln!("failed to read metadata: {}", e),
                        }
                    }
                    if let Some(pid) = args.pid {
                        println!("PID: {}", pid);
                    }
                }
                let event = DapMessage::Event(Event {
                    base: ProtocolMessage {
                        seq,
                        type_: "event".to_string(),
                    },
                    event: "initialized".to_string(),
                    body: json!({}),
                });
                seq += 1;
                dap::write_message(&mut writer, &event)?;
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
                dap::write_message(&mut writer, &resp)?;
            }
            _ => {}
        }
    }
    Ok(())
}
