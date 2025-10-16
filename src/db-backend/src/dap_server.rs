use crate::dap::{self, Capabilities, DapMessage, Event, ProtocolMessage, Response};
use crate::dap_types;

use crate::db::Db;
use crate::handler::Handler;
use crate::paths::CODETRACER_PATHS;
use crate::rr_dispatcher::CtRRArgs;
use crate::task::{
    Action, CallSearchArg, CalltraceLoadArgs, CollapseCallsArgs, CtLoadFlowArguments,
    CtLoadLocalsArguments, FunctionLocation, LoadHistoryArg, LocalStepJump, Location, ProgramEvent, RunTracepointsArg,
    SourceCallJumpTarget, SourceLocation, StepArg, TraceKind, TracepointId, UpdateTableArgs,
};

use crate::trace_processor::{load_trace_data, load_trace_metadata, TraceProcessor};

use crate::transport::DapTransport;

#[cfg(feature = "browser-transport")]
use crate::transport::{DapResult, WorkerTransport};

use log::{info, warn};
use serde_json::json;
// use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::fmt;

#[cfg(feature = "io-transport")]
use std::io::BufReader;

#[cfg(feature = "io-transport")]
use std::os::unix::net::UnixStream;

use std::path::{Path, PathBuf};

pub const DAP_SOCKET_NAME: &str = "ct_dap_socket";

#[cfg(feature = "io-transport")]
pub fn make_io_transport() -> Result<(BufReader<std::io::StdinLock<'static>>, std::io::Stdout), Box<dyn Error>> {
    use std::io::BufReader;

    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let reader = BufReader::new(stdin.lock());
    Ok((reader, stdout))
}

#[cfg(feature = "io-transport")]
pub fn make_socket_transport(
    socket_path: &PathBuf,
) -> Result<(std::io::BufReader<UnixStream>, UnixStream), Box<dyn Error>> {
    use std::io::BufReader;

    let stream = UnixStream::connect(socket_path)?;
    let reader = BufReader::new(stream.try_clone()?);
    let writer = stream;
    Ok((reader, writer))
}

#[cfg(feature = "browser-transport")]
pub fn make_transport() -> DapResult<WorkerTransport> {
    WorkerTransport::new()
}

pub fn socket_path_for(pid: usize) -> PathBuf {
    CODETRACER_PATHS
        .lock()
        .unwrap()
        .tmp_path
        .join(format!("{DAP_SOCKET_NAME}_{}.sock", pid))
}

#[cfg(feature = "io-transport")]
pub fn run_stdio() -> Result<(), Box<dyn Error>> {
    // let mut transport = make_io_transport().unwrap();

    let (mut reader, mut writer) = make_io_transport().unwrap();

    handle_client(&mut reader, &mut writer)
}

#[cfg(feature = "io-transport")]
pub fn run(socket_path: &PathBuf) -> Result<(), Box<dyn Error>> {
    // let mut transport = make_io_transport().unwrap();

    let (mut reader, mut writer) = make_socket_transport(socket_path)?;

    handle_client(&mut reader, &mut writer)
}

fn launch(
    trace_folder: &Path,
    trace_file: &Path,
    raw_diff_index: Option<String>,
    ct_rr_worker_exe: &Path,
    seq: i64,
) -> Result<Handler, Box<dyn Error>> {
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
    if let (Ok(meta), Ok(trace)) = (
        load_trace_metadata(&metadata_path),
        load_trace_data(&trace_path, trace_file_format),
    ) {
        let mut db = Db::new(&meta.workdir);
        let mut proc = TraceProcessor::new(&mut db);
        proc.postprocess(&trace)?;

        let mut handler = Handler::new(TraceKind::DB, CtRRArgs::default(), Box::new(db));
        handler.dap_client.seq = seq;
        handler.raw_diff_index = raw_diff_index;
        handler.run_to_entry(dap::Request::default())?;
        Ok(handler)
    } else {
        warn!("problem with reading metadata or path trace files: try rr?");
        let path = trace_folder.join("rr").join("latest-trace");
        if path.exists() {
            let db = Db::new(&PathBuf::from(""));
            let ct_rr_args = CtRRArgs {
                worker_exe: PathBuf::from(ct_rr_worker_exe),
                rr_trace_folder: path,
            };
            let mut handler = Handler::new(TraceKind::RR, ct_rr_args, Box::new(db));
            handler.dap_client.seq = seq;
            handler.raw_diff_index = raw_diff_index;
            handler.run_to_entry(dap::Request::default())?;
            Ok(handler)
        } else {
            Err("problem with reading metadata or path trace files".into())
        }
    }
}

fn write_dap_messages<T: DapTransport>(
    transport: &mut T,
    handler: &mut Handler,
    seq: &mut i64,
) -> Result<(), Box<dyn Error>> {
    for message in &handler.resulting_dap_messages {
        transport.send(message)?;
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

fn handle_request<T: DapTransport>(
    handler: &mut Handler,
    req: dap::Request,
    seq: &mut i64,
    transport: &mut T,
) -> Result<(), Box<dyn Error>> {
    handler.dap_client.seq = *seq;
    match req.command.as_str() {
        "scopes" => handler.scopes(req.clone(), req.load_args::<dap_types::ScopesArguments>()?)?,
        "threads" => handler.threads(req.clone())?,
        "stackTrace" => handler.stack_trace(req.clone(), req.load_args::<dap_types::StackTraceArguments>()?)?,
        "variables" => handler.variables(req.clone(), req.load_args::<dap_types::VariablesArguments>()?)?,
        "restart" => handler.run_to_entry(req.clone())?,
        "setBreakpoints" => handler.set_breakpoints(req.clone(), req.load_args::<dap_types::SetBreakpointsArguments>()?)?,
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
        "ct/load-flow" => handler.load_flow(req.clone(), req.load_args::<CtLoadFlowArguments>()?)?,
        "ct/run-to-entry" => handler.run_to_entry(req.clone())?,
        "ct/run-tracepoints" => handler.run_tracepoints(req.clone(), req.load_args::<RunTracepointsArg>()?)?,
        "ct/setup-trace-session" => handler.setup_trace_session(req.clone(), req.load_args::<RunTracepointsArg>()?)?,
        "ct/load-calltrace-section" => {
            // TODO: log this when logging logic is properly abstracted
            // info!("load_calltrace_section");
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
                    // error!("unsupported dap command: {}", req.command);
                    return Err(format!("command {} not supported here", req.command).into());
                }
            }
        }
    }
    write_dap_messages(transport, handler, seq)
}

pub struct Ctx {
    pub seq: i64,
    pub handler: Option<Handler>,
    pub received_launch: bool,
    pub launch_trace_folder: PathBuf,
    pub launch_trace_file: PathBuf,
    pub launch_raw_diff_index: Option<String>,
    pub ct_rr_worker_exe: PathBuf,
    pub received_configuration_done: bool,
}

impl Default for Ctx {
    fn default() -> Self {
        Self {
            seq: 1i64,
            handler: None,
            received_launch: false,
            launch_trace_folder: PathBuf::from(""),
            launch_trace_file: PathBuf::from(""),
            launch_raw_diff_index: None,
            ct_rr_worker_exe: PathBuf::from(""),
            received_configuration_done: false,
        }
    }
}

pub fn handle_message<T: DapTransport>(
    msg: &DapMessage,
    transport: &mut T,
    ctx: &mut Ctx,
) -> Result<(), Box<dyn Error>> {
    info!("Handling message: {:?}", msg);
    if let DapMessage::Request(req) = msg {
        info!("  request {}", req.command);
    }

    match msg {
        DapMessage::Request(req) if req.command == "initialize" => {
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
                    seq: ctx.seq,
                    type_: "response".to_string(),
                },
                request_seq: req.base.seq,
                success: true,
                command: "initialize".to_string(),
                message: None,
                body: serde_json::to_value(capabilities)?,
            });
            ctx.seq += 1;

            transport.send(&resp)?;

            let event = DapMessage::Event(Event {
                base: ProtocolMessage {
                    seq: ctx.seq,
                    type_: "event".to_string(),
                },
                event: "initialized".to_string(),
                body: json!({}),
            });
            ctx.seq += 1;
            transport.send(&event)?;
        }
        DapMessage::Request(req) if req.command == "launch" => {
            ctx.received_launch = true;
            let args = req.load_args::<dap::LaunchRequestArguments>()?;
            if let Some(folder) = &args.trace_folder {
                ctx.launch_trace_folder = folder.clone();
                if let Some(trace_file) = &args.trace_file {
                    ctx.launch_trace_file = trace_file.clone();
                } else {
                    ctx.launch_trace_file = "trace.json".into();
                }

                // TODO: log this when logging logic is properly abstracted
                //info!("stored launch trace folder: {0:?}", ctx.launch_trace_folder)

                ctx.launch_raw_diff_index = args.raw_diff_index.clone();
                ctx.ct_rr_worker_exe = args.ct_rr_worker_exe.unwrap_or(PathBuf::from(""));

                if ctx.received_configuration_done {
                    ctx.handler = Some(launch(
                        &ctx.launch_trace_folder,
                        &ctx.launch_trace_file,
                        ctx.launch_raw_diff_index.clone(),
                        &ctx.ct_rr_worker_exe,
                        ctx.seq)?);
                    if let Some(h) = ctx.handler.as_mut() {
                        write_dap_messages(transport, h, &mut ctx.seq)?;
                    }
                }
            }
            // TODO: log this when logging logic is properly abstracted
            // info!(
            //     "received launch; configuration done? {0:?}; req: {1:?}",
            //     ctx.received_configuration_done, req
            // );

            let resp = DapMessage::Response(Response {
                base: ProtocolMessage {
                    seq: ctx.seq,
                    type_: "response".to_string(),
                },
                request_seq: req.base.seq,
                success: true,
                command: "launch".to_string(),
                message: None,
                body: json!({}),
            });
            ctx.seq += 1;
            transport.send(&resp)?;
        }
        DapMessage::Request(req) if req.command == "configurationDone" => {
            // TODO: run to entry/continue here, after setting the `launch` field
            ctx.received_configuration_done = true;
            let resp = DapMessage::Response(Response {
                base: ProtocolMessage {
                    seq: ctx.seq,
                    type_: "response".to_string(),
                },
                request_seq: req.base.seq,
                success: true,
                command: "configurationDone".to_string(),
                message: None,
                body: json!({}),
            });
            ctx.seq += 1;
            transport.send(&resp)?;

            // TODO: log this when logging logic is properly abstracted
            // info!(
            //     "configuration done sent response; received_launch: {0:?}",
            //     ctx.received_launch
            // );
            if ctx.received_launch {
                ctx.handler = Some(launch(
                    &ctx.launch_trace_folder,
                    &ctx.launch_trace_file,
                    ctx.launch_raw_diff_index.clone(),
                    &ctx.ct_rr_worker_exe,
                    ctx.seq)?);
                if let Some(h) = ctx.handler.as_mut() {
                    write_dap_messages(transport, h, &mut ctx.seq)?;
                }
            }
        }
        DapMessage::Request(req) if req.command == "disconnect" => {
            if let Some(h) = ctx.handler.as_mut() {
                let args: dap_types::DisconnectArguments = req.load_args()?;
                h.dap_client.seq = ctx.seq;
                h.respond_to_disconnect(req.clone(), args)?;
                write_dap_messages(transport, h, &mut ctx.seq)?;

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
            if let Some(h) = ctx.handler.as_mut() {
                let res = handle_request(h, req.clone(), &mut ctx.seq, transport);
                if let Err(_e) = res {
                    // warn!("handle_request error: {e:?}");
                }
            }
        }
        _ => {}
    }

    Ok(())
}

#[cfg(feature = "io-transport")]
fn handle_client<R: std::io::BufRead, T: DapTransport>(
    reader: &mut R,
    transport: &mut T,
) -> Result<(), Box<dyn Error>> {
    use log::error;

    let mut ctx = Ctx::default();

    while let Ok(msg) = dap::read_dap_message_from_reader(reader) {
        let _ = handle_message(&msg, transport, &mut ctx);
    }

    error!("maybe error from reader");
    Ok(())
}
