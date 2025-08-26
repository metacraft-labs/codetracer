use crate::dap::{self, Capabilities, DapMessage, Event, ProtocolMessage, Response};
use crate::dap_types;
use crate::db::Db;
use crate::handler::Handler;
use crate::task::{
    gen_task_id, Action, CallSearchArg, CalltraceLoadArgs, CollapseCallsArgs, CtLoadLocalsArguments, FunctionLocation,
    LoadHistoryArg, LocalStepJump, Location, ProgramEvent, RunTracepointsArg, SourceCallJumpTarget, SourceLocation,
    StepArg, Task, TaskKind, TracepointId, UpdateTableArgs,
};
use crate::trace_processor::{load_trace_data, load_trace_metadata, TraceProcessor};
use log::{error, info, warn};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::fmt;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::time::Instant;

// fn forward_raw_events<W: Write>(
//     rx: &mpsc::Receiver<BackendResponse>,
//     writer: &mut W,
//     seq: &mut i64,
// ) -> Result<(), Box<dyn Error>> {
//     while let Ok(BackendResponse::EventResponse((kind, _id, payload, raw))) = rx.try_recv() {
//         if raw && matches!(kind, EventKind::MissingEventKind) {
//             if let Ok(DapMessage::Event(mut ev)) = dap::from_json(&payload) {
//                 ev.base.seq = *seq;
//                 *seq += 1;
//                 dap::write_message(writer, &DapMessage::Event(ev))?;
//             }
//         }
//     }
//     Ok(())
// }

pub const DAP_SOCKET_PATH: &str = "/tmp/ct_dap_socket";

pub fn socket_path_for(pid: usize) -> PathBuf {
    PathBuf::from(format!("{DAP_SOCKET_PATH}_{}", pid))
}

pub fn run(socket_path: &Path) -> Result<(), Box<dyn Error>> {
    info!("dap_server::run {:?}", socket_path);
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

fn launch(trace_folder: &Path, trace_file: &Path, seq: i64) -> Result<Handler, Box<dyn Error>> {
    info!("run launch() for {:?}", trace_folder);
    let trace_file_format = if trace_file.extension() == Some(std::ffi::OsStr::new("json")) {
        runtime_tracing::TraceEventsFileFormat::Json
    } else {
        runtime_tracing::TraceEventsFileFormat::Binary
    };
    let metadata_path = trace_folder.join("trace_metadata.json");
    let trace_path = trace_folder.join(trace_file);
    // duration code copied from
    // https://rust-lang-nursery.github.io/rust-cookbook/datetime/duration.html
    let start = Instant::now();
    if let (Ok(meta), Ok(trace)) = (
        load_trace_metadata(&metadata_path),
        load_trace_data(&trace_path, trace_file_format),
    ) {
        let duration = start.elapsed();
        info!("loading trace: duration: {:?}", duration);

        let start2 = Instant::now();
        let mut db = Db::new(&meta.workdir);
        let mut proc = TraceProcessor::new(&mut db);
        proc.postprocess(&trace)?;

        let duration2 = start2.elapsed();
        info!("postprocessing trace: duration: {:?}", duration2);

        // eprintln!("TRACE METADATA: {:?}", meta);
        let mut handler = Handler::new(Box::new(db));
        handler.dap_client.seq = seq;
        handler.run_to_entry(dap::Request::default())?;
        Ok(handler)
    } else {
        Err("problem with reading metadata or path trace files".into())
    }
}

fn write_dap_messages<W: Write>(writer: &mut W, handler: &mut Handler, seq: &mut i64) -> Result<(), Box<dyn Error>> {
    for message in &handler.resulting_dap_messages {
        dap::write_message(writer, message)?;
    }
    handler.reset_dap();
    *seq = handler.dap_client.seq;
    Ok(())
}

#[derive(Debug, Clone)]
struct CtDapError {
    message: String,
}

impl CtDapError {
    pub fn new(message: &str) -> Self {
        CtDapError {
            message: message.to_string(),
        }
    }
}

impl fmt::Display for CtDapError {
    fn fmt(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        write!(formatter, "Ct dap error: {}", self.message)
    }
}

type IsReverseAction = bool;

fn dap_command_to_step_action(command: &str) -> Result<(Action, IsReverseAction), CtDapError> {
    match command {
        "stepIn" => Ok((Action::StepIn, false)),
        "stepOut" => Ok((Action::StepOut, false)),
        "next" => Ok((Action::Next, false)),
        "continue" => Ok((Action::Continue, false)),
        "stepBack" => Ok((Action::Next, true)),
        "reverseContinue" => Ok((Action::Continue, true)),
        // custom for codetracer
        "ct/reverseStepIn" => Ok((Action::StepIn, true)),
        "ct/reverseStepOut" => Ok((Action::StepOut, true)),
        _ => Err(CtDapError::new(&format!("not a recognized dap step action: {command}"))),
    }
}

fn handle_request<W: Write>(
    handler: &mut Handler,
    req: dap::Request,
    seq: &mut i64,
    writer: &mut W,
) -> Result<(), Box<dyn Error>> {
    handler.dap_client.seq = *seq;
    match req.command.as_str() {
        "scopes" => handler.scopes(req.clone(), req.load_args::<dap_types::ScopesArguments>()?)?,
        "threads" => handler.threads(req.clone())?,
        "stackTrace" => handler.stack_trace(req.clone(), req.load_args::<dap_types::StackTraceArguments>()?)?,
        "variables" => handler.variables(req.clone(), req.load_args::<dap_types::VariablesArguments>()?)?,
        "restart" => handler.run_to_entry(req.clone())?,
        "ct/load-locals" => handler.load_locals(req.clone(), req.load_args::<CtLoadLocalsArguments>()?)?,
        "ct/update-table" => handler.update_table(req.clone(), req.load_args::<UpdateTableArgs>()?)?,
        "ct/event-load" => handler.event_load(req.clone())?,
        "ct/load-terminal" => handler.load_terminal(req.clone())?,
        "ct/collapse-calls" => handler.collapse_calls(req.clone(), req.load_args::<CollapseCallsArgs>()?)?,
        "ct/expand-calls" => handler.expand_calls(req.clone(), req.load_args::<CollapseCallsArgs>()?)?,
        "ct/calltrace-jump" => handler.calltrace_jump(req.clone(), req.load_args::<Location>()?)?,
        "ct/event-jump" => handler.event_jump(req.clone(), req.load_args::<ProgramEvent>()?)?,
        "ct/load-history" => handler.load_history(req.clone(), req.load_args::<LoadHistoryArg>()?)?,
        "ct/history-jump" => handler.history_jump(req.clone(), req.load_args::<Location>()?)?,
        "ct/search-calltrace" => handler.calltrace_search(req.clone(), req.load_args::<CallSearchArg>()?)?,
        "ct/source-line-jump" => handler.source_line_jump(req.clone(), req.load_args::<SourceLocation>()?)?,
        "ct/source-call-jump" => handler.source_call_jump(req.clone(), req.load_args::<SourceCallJumpTarget>()?)?,
        "ct/local-step-jump" => handler.local_step_jump(req.clone(), req.load_args::<LocalStepJump>()?)?,
        "ct/tracepoint-toggle" => handler.tracepoint_toggle(req.clone(), req.load_args::<TracepointId>()?)?,
        "ct/tracepoint-delete" => handler.tracepoint_delete(req.clone(), req.load_args::<TracepointId>()?)?,
        "ct/trace-jump" => handler.trace_jump(req.clone(), req.load_args::<ProgramEvent>()?)?,
        "ct/load-flow" => handler.load_flow(req.clone(), req.load_args::<Location>()?)?,
        "ct/run-to-entry" => handler.run_to_entry(req.clone())?,
        "ct/run-tracepoints" => handler.run_tracepoints(req.clone(), req.load_args::<RunTracepointsArg>()?)?,
        "ct/setup-trace-session" => handler.setup_trace_session(req.clone(), req.load_args::<RunTracepointsArg>()?)?,
        "ct/load-calltrace-section" => {
            info!("load_calltrace_section");
            handler.load_calltrace_section(req.clone(), req.load_args::<CalltraceLoadArgs>()?)?
        }
        "ct/load-asm-function" => handler.load_asm_function(req.clone(), req.load_args::<FunctionLocation>()?)?,
        _ => {
            match dap_command_to_step_action(&req.command) {
                Ok((action, is_reverse)) => {
                    // for now ignoring arguments: they contain threadId, but
                    // we assume we have a single thread here for now
                    // we also don't use the other args currently
                    handler.step(req, StepArg::new(action, is_reverse))?;
                }
                Err(_e) => {
                    // TODO: eventually support? or if this is the last  branch
                    // in the top `match`
                    // assume all request left here are unsupported
                    error!("unsupported dap command: {}", req.command);
                    return Err(format!("command {} not supported here", req.command).into());
                }
            }
        }
    }
    write_dap_messages(writer, handler, seq)
}

fn handle_client<R: BufRead, W: Write>(reader: &mut R, writer: &mut W) -> Result<(), Box<dyn Error>> {
    let mut seq = 1i64;
    let mut breakpoints: HashMap<String, HashSet<i64>> = HashMap::new();
    // let (tx, _rx) = mpsc::channel();
    let mut handler: Option<Handler> = None;
    let mut received_launch = false;
    let mut launch_trace_folder = PathBuf::from("");
    let mut launch_trace_file = PathBuf::from("");
    let mut received_configuration_done = false;
    while let Ok(msg) = dap::from_reader(reader) {
        info!("DAP <- {:?}", msg);

        match msg {
            DapMessage::Request(req) if req.command == "initialize" => {
                // TODO: process client capabilities
                let capabilities = Capabilities {
                    supports_loaded_sources_request: Some(false),
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
                    body: serde_json::to_value(capabilities)?,
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
                let args = req.load_args::<dap_types::SetBreakpointsArguments>()?;
                if let Some(path) = args.source.path.clone() {
                    let lines: Vec<i64> = if let Some(bps) = args.breakpoints {
                        bps.into_iter().map(|b| b.line).collect()
                    } else {
                        args.lines.unwrap_or_default()
                    };
                    let entry = breakpoints.entry(path.clone()).or_default();
                    if let Some(h) = handler.as_mut() {
                        h.clear_breakpoints();
                        for line in lines {
                            entry.insert(line);
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
                            results.push(dap_types::Breakpoint {
                                id: None,
                                verified: true,
                                message: None,
                                source: Some(dap_types::Source {
                                    name: args.source.name.clone(),
                                    path: Some(path.clone()),
                                    source_reference: args.source.source_reference,
                                    adapter_data: None,
                                    checksums: None,
                                    origin: None,
                                    presentation_hint: None,
                                    sources: None,
                                }),
                                line: Some(line),
                                column: None,
                                end_line: None,
                                end_column: None,
                                instruction_reference: None,
                                offset: None,
                                reason: None,
                            });
                        }
                    }
                } else {
                    let lines = args
                        .breakpoints
                        .unwrap_or_default()
                        .into_iter()
                        .map(|b| b.line)
                        .collect::<Vec<_>>();
                    for line in lines {
                        results.push(dap_types::Breakpoint {
                            id: None,
                            verified: false,
                            message: Some("missing source path".to_string()),
                            source: None,
                            line: Some(line),
                            column: None,
                            end_line: None,
                            end_column: None,
                            instruction_reference: None,
                            offset: None,
                            reason: None,
                        });
                    }
                }
                let body = dap_types::SetBreakpointsResponseBody { breakpoints: results };
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
                let args = req.load_args::<dap::LaunchRequestArguments>()?;
                if let Some(folder) = &args.trace_folder {
                    launch_trace_folder = folder.clone();
                    if let Some(trace_file) = &args.trace_file {
                        launch_trace_file = trace_file.clone();
                    } else {
                        launch_trace_file = "trace.json".into();
                    }
                    info!("stored launch trace folder: {launch_trace_folder:?}");
                    if received_configuration_done {
                        handler = Some(launch(&launch_trace_folder, &launch_trace_file, seq)?);
                        if let Some(h) = handler.as_mut() {
                            write_dap_messages(writer, h, &mut seq)?;
                        }
                    }
                    // if let Some(pid) = args.pid {
                    // eprintln!("PID: {}", pid);
                    // }
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
                    handler = Some(launch(&launch_trace_folder, &launch_trace_file, seq)?);
                    if let Some(h) = handler.as_mut() {
                        write_dap_messages(writer, h, &mut seq)?;
                    }
                }
            }
            DapMessage::Request(req) if req.command == "disconnect" => {
                if let Some(h) = handler.as_mut() {
                    let args = req.load_args::<dap_types::DisconnectArguments>()?;
                    h.dap_client.seq = seq;
                    h.respond_to_disconnect(req, args)?;
                    write_dap_messages(writer, h, &mut seq)?;

                    // > The disconnect request asks the debug adapter to disconnect from the debuggee (thus ending the debug session)
                    // > and then to shut down itself (the debug adapter).
                    // (https://microsoft.github.io/debug-adapter-protocol//specification.html#Requests_Disconnect)
                    // we don't have a debuggee process, just a db, so we just stop db-backend for now
                    // (and before that, we respond to the request, acknowledging it)
                    //
                    // we allow it for now here, but if additional cleanup is needed, maybe we'd need
                    // to return to upper functions
                    #[allow(clippy::exit)]
                    std::process::exit(0);
                }
            }
            DapMessage::Request(req) => {
                if let Some(h) = handler.as_mut() {
                    let res = handle_request(h, req, &mut seq, writer);
                    if let Err(e) = res {
                        warn!("handle_request error: {e:?}");
                    }
                }
            }
            _ => {}
        }
        // forward_raw_events(&rx, writer, &mut seq)?;
    }
    error!("maybe error from reader");
    Ok(())
}
