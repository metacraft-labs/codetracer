use serde_json::json;
// use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::fmt;
#[cfg(feature = "io-transport")]
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

use log::{debug, error, info, warn};

use crate::dap::{self, Capabilities, DapMessage, Event, ProtocolMessage, Response};
use crate::dap_types;

use crate::db::Db;
use crate::handler::Handler;
use crate::paths::CODETRACER_PATHS;
use crate::rr_dispatcher::CtRRArgs;
use crate::task::{
    Action, CallSearchArg, CalltraceLoadArgs, CollapseCallsArgs, CtLoadFlowArguments, CtLoadLocalsArguments,
    FunctionLocation, LoadHistoryArg, LocalStepJump, Location, ProgramEvent, RunTracepointsArg, SourceCallJumpTarget,
    SourceLocation, StepArg, TraceKind, TracepointId, UpdateTableArgs,
};

use crate::trace_processor::{load_trace_data, load_trace_metadata, TraceProcessor};

use crate::transport::DapTransport;

#[cfg(feature = "browser-transport")]
use crate::transport::{DapResult, WorkerTransport};

pub const DAP_SOCKET_NAME: &str = "ct_dap_socket";

// in the future: maybe refactor in a more thread-aware way?
//   or if not: delete

// #[cfg(feature = "io-transport")]
// pub fn make_io_transport() -> Result<(BufReader<std::io::StdinLock<'static>>, std::io::Stdout), Box<dyn Error>> {
//     use std::io::BufReader;

//     let stdin = std::io::stdin();
//     let stdout = std::io::stdout();
//     let reader = BufReader::new(stdin.lock());
//     Ok((reader, stdout))
// }

// #[cfg(feature = "io-transport")]
// pub fn make_socket_transport(
//     socket_path: &PathBuf,
// ) -> Result<(std::io::BufReader<UnixStream>, UnixStream), Box<dyn Error>> {
//     use std::io::BufReader;

//     let stream = UnixStream::connect(socket_path)?;
//     let reader = BufReader::new(stream.try_clone()?);
//     let writer = stream;
//     Ok((reader, writer))
// }

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
    use std::io::BufReader;

    // let mut transport = make_io_transport().unwrap();

    let (receiving_sender, receiving_receiver) = mpsc::channel();
    let builder = thread::Builder::new().name("receiving".to_string());
    let receiving_thread = builder.spawn(move || -> Result<(), String> {
        info!("receiving thread");
        let stdin = std::io::stdin();
        let mut reader = BufReader::new(stdin.lock());

        loop {
            info!("waiting for new stdio DAP message");
            match dap::read_dap_message_from_reader(&mut reader) {
                Ok(msg) => {
                    receiving_sender.send(msg).map_err(|e| {
                        error!("send error: {e:?}");
                        format!("send error: {e:?}")
                    })?;
                }
                Err(e) => {
                    error!("error from read_dap_message_from_reader: {e:?}");
                    break;
                }
            }
        }
        Ok(())
    })?;

    handle_client(receiving_receiver, true, &receiving_thread, None)
}

#[cfg(feature = "io-transport")]
pub fn run(socket_path: &PathBuf) -> Result<(), Box<dyn Error>> {
    use std::io::BufReader;

    let (receiving_sender, receiving_receiver) = mpsc::channel();

    let socket_path_owned = socket_path.clone();

    let stream = UnixStream::connect(&socket_path_owned)?;
    let writer = stream.try_clone()?;
    info!("stream ok out of thread");

    let builder = thread::Builder::new().name("receiving".to_string());
    let receiving_thread = builder.spawn(move || -> Result<(), String> {
        info!("receiving thread");
        let mut reader = BufReader::new(stream.try_clone().map_err(|e| {
            error!("buf reader try_clone error: {e:?}");
            format!("buf reader try_clone error: {e:?}")
        })?);

        loop {
            info!("waiting for new socket DAP message");
            match dap::read_dap_message_from_reader(&mut reader) {
                Ok(msg) => {
                    receiving_sender.send(msg).map_err(|e| {
                        error!("send error: {e:?}");
                        format!("send error: {e:?}")
                    })?;
                }
                Err(e) => {
                    error!("error from read_dap_message_from_reader: {e:?}");
                    break;
                }
            }
        }
        Ok(())
    })?;

    handle_client(receiving_receiver, false, &receiving_thread, Some(writer))
}

fn setup(
    trace_folder: &Path,
    trace_file: &Path,
    raw_diff_index: Option<String>,
    ct_rr_worker_exe: &Path,
    restore_location: Option<Location>,
    sender: Sender<DapMessage>,
    for_launch: bool,
    thread_name: &str,
) -> Result<Handler, Box<dyn Error>> {
    info!("run setup() for {:?}", trace_folder);
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

        let mut handler = Handler::new(
            TraceKind::DB,
            CtRRArgs {
                name: thread_name.to_string(),
                ..CtRRArgs::default()
            },
            Box::new(db),
        );
        handler.raw_diff_index = raw_diff_index;
        if for_launch {
            handler.run_to_entry(dap::Request::default(), restore_location, sender)?;
        }
        handler.initialized = true;
        Ok(handler)
    } else {
        info!("can't read db metadata or path trace files: try to read as rr trace");
        let path = trace_folder.join("rr");
        if path.exists() {
            let db = Db::new(&PathBuf::from(""));
            let ct_rr_args = CtRRArgs {
                worker_exe: PathBuf::from(ct_rr_worker_exe),
                rr_trace_folder: path,
                name: thread_name.to_string(),
            };
            info!("ct_rr_args {:?}", ct_rr_args);
            let mut handler = Handler::new(TraceKind::RR, ct_rr_args, Box::new(db));
            handler.raw_diff_index = raw_diff_index;
            if for_launch {
                handler.run_to_entry(dap::Request::default(), restore_location, sender)?;
            }
            handler.initialized = true;
            Ok(handler)
        } else {
            Err("problem with reading metadata or path trace files".into())
        }
    }
}

fn patch_message_seq(message: &DapMessage, seq: i64) -> DapMessage {
    match message {
        DapMessage::Request(r) => {
            let mut r_with_seq = r.clone();
            r_with_seq.base.seq = seq;
            DapMessage::Request(r_with_seq)
        }
        DapMessage::Response(r) => {
            let mut r_with_seq = r.clone();
            r_with_seq.base.seq = seq;
            DapMessage::Response(r_with_seq)
        }
        DapMessage::Event(e) => {
            let mut e_with_seq = e.clone();
            e_with_seq.base.seq = seq;
            DapMessage::Event(e_with_seq)
        }
    }
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

fn handle_request(handler: &mut Handler, req: dap::Request, sender: Sender<DapMessage>) -> Result<(), Box<dyn Error>> {
    match req.command.as_str() {
        "scopes" => handler.scopes(
            req.clone(),
            req.load_args::<dap_types::ScopesArguments>()?,
            sender.clone(),
        )?,
        "threads" => handler.threads(req.clone(), sender.clone())?,
        "stackTrace" => handler.stack_trace(
            req.clone(),
            req.load_args::<dap_types::StackTraceArguments>()?,
            sender.clone(),
        )?,
        "variables" => handler.variables(
            req.clone(),
            req.load_args::<dap_types::VariablesArguments>()?,
            sender.clone(),
        )?,
        "restart" => handler.run_to_entry(req.clone(), None, sender.clone())?,
        "setBreakpoints" => handler.set_breakpoints(
            req.clone(),
            req.load_args::<dap_types::SetBreakpointsArguments>()?,
            sender.clone(),
        )?,
        "ct/load-locals" => {
            handler.load_locals(req.clone(), req.load_args::<CtLoadLocalsArguments>()?, sender.clone())?
        }
        "ct/update-table" => handler.update_table(req.clone(), req.load_args::<UpdateTableArgs>()?, sender.clone())?,
        "ct/event-load" => handler.event_load(req.clone(), sender.clone())?,
        "ct/load-terminal" => handler.load_terminal(req.clone(), sender.clone())?,
        "ct/collapse-calls" => handler.collapse_calls(req.clone(), req.load_args::<CollapseCallsArgs>()?)?,
        "ct/expand-calls" => handler.expand_calls(req.clone(), req.load_args::<CollapseCallsArgs>()?)?,
        "ct/calltrace-jump" => handler.calltrace_jump(req.clone(), req.load_args::<Location>()?, sender.clone())?,
        "ct/event-jump" => handler.event_jump(req.clone(), req.load_args::<ProgramEvent>()?, sender.clone())?,
        "ct/load-history" => handler.load_history(req.clone(), req.load_args::<LoadHistoryArg>()?, sender.clone())?,
        "ct/history-jump" => handler.history_jump(req.clone(), req.load_args::<Location>()?, sender.clone())?,
        "ct/search-calltrace" => {
            handler.calltrace_search(req.clone(), req.load_args::<CallSearchArg>()?, sender.clone())?
        }
        "ct/source-line-jump" => {
            handler.source_line_jump(req.clone(), req.load_args::<SourceLocation>()?, sender.clone())?
        }
        "ct/source-call-jump" => {
            handler.source_call_jump(req.clone(), req.load_args::<SourceCallJumpTarget>()?, sender.clone())?
        }
        "ct/local-step-jump" => {
            handler.local_step_jump(req.clone(), req.load_args::<LocalStepJump>()?, sender.clone())?
        }
        "ct/tracepoint-toggle" => {
            handler.tracepoint_toggle(req.clone(), req.load_args::<TracepointId>()?, sender.clone())?
        }
        "ct/tracepoint-delete" => {
            handler.tracepoint_delete(req.clone(), req.load_args::<TracepointId>()?, sender.clone())?
        }
        "ct/trace-jump" => handler.trace_jump(req.clone(), req.load_args::<ProgramEvent>()?, sender.clone())?,
        "ct/load-flow" => handler.load_flow(req.clone(), req.load_args::<CtLoadFlowArguments>()?, sender.clone())?,
        "ct/run-to-entry" => handler.run_to_entry(req.clone(), None, sender.clone())?,
        "ct/run-tracepoints" => {
            handler.run_tracepoints(req.clone(), req.load_args::<RunTracepointsArg>()?, sender.clone())?
        }
        "ct/setup-trace-session" => {
            handler.setup_trace_session(req.clone(), req.load_args::<RunTracepointsArg>()?, sender.clone())?
        }
        "ct/load-calltrace-section" => {
            // TODO: log this when logging logic is properly abstracted
            // info!("load_calltrace_section");

            // it's ok for this to fail with serialization null errors for example
            //   when there are `null` fields in `location`. this can happen when
            //   there is no high level file open/debuginfo for the current location
            //   in this case, the code calling `handle_request` should handle the error
            //   and usually for the client to just not receive a new callstack/calltrace
            //   (maybe to receive a clear error in the future?)
            handler.load_calltrace_section(req.clone(), req.load_args::<CalltraceLoadArgs>()?, sender.clone())?
        }
        "ct/load-asm-function" => {
            handler.load_asm_function(req.clone(), req.load_args::<FunctionLocation>()?, sender.clone())?
        }
        _ => {
            match dap_command_to_step_action(&req.command) {
                Ok((action, is_reverse)) => {
                    // for now ignoring arguments: they contain threadId, but
                    // we assume we have a single thread here for now
                    // we also don't use the other args currently
                    handler.step(req, StepArg::new(action, is_reverse), sender.clone())?;
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
    Ok(())
    // write_dap_messages_from_thread(sender, handler, seq)
}

#[derive(Debug, Clone)]
pub struct Ctx {
    pub seq: i64,
    // pub handler: Option<Handler>,
    // pub received_launch: bool,
    pub launch_request: Option<dap::Request>,
    pub launch_trace_folder: PathBuf,
    pub launch_trace_file: PathBuf,
    pub launch_raw_diff_index: Option<String>,
    pub ct_rr_worker_exe: PathBuf,
    pub restore_location: Option<Location>,
    pub received_configuration_done: bool,

    pub to_stable_sender: Option<Sender<dap::Request>>,
    pub to_flow_sender: Option<Sender<dap::Request>>,
    pub to_tracepoint_sender: Option<Sender<dap::Request>>,
}

impl Default for Ctx {
    fn default() -> Self {
        Self {
            seq: 1i64,
            // handler: None,
            // received_launch: false,
            launch_request: None,
            launch_trace_folder: PathBuf::from(""),
            launch_trace_file: PathBuf::from(""),
            launch_raw_diff_index: None,
            ct_rr_worker_exe: PathBuf::from(""),
            restore_location: None,
            received_configuration_done: false,

            to_stable_sender: None,
            to_flow_sender: None,
            to_tracepoint_sender: None,
        }
    }
}

impl Ctx {
    fn write_dap_messages(
        // <T: DapTransport>(
        &mut self,
        sender: Sender<DapMessage>, // transport: &mut T,
        messages: &[DapMessage],
    ) -> Result<(), Box<dyn Error>> {
        for message in messages {
            let message_with_seq = patch_message_seq(&message, self.seq);
            self.seq += 1;
            sender.send(message_with_seq)?;
        }
        Ok(())
    }
}

pub fn handle_message(msg: &DapMessage, sender: Sender<DapMessage>, ctx: &mut Ctx) -> Result<(), Box<dyn Error>> {
    debug!("Handling message: {:?}", msg);

    if let DapMessage::Request(req) = msg {
        info!("handle request {}", req.command);
    } else {
        warn!(
            "handle other kind of message: unexpected; expected a request, but handles: {:?}",
            msg
        );
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
            ctx.write_dap_messages(sender.clone(), &[resp])?;

            let event = DapMessage::Event(Event {
                base: ProtocolMessage {
                    seq: ctx.seq,
                    type_: "event".to_string(),
                },
                event: "initialized".to_string(),
                body: json!({}),
            });
            ctx.write_dap_messages(sender, &[event])?;
        }
        DapMessage::Request(req) if req.command == "launch" => {
            // ctx.received_launch = true;
            ctx.launch_request = Some(req.clone());
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
                ctx.restore_location = args.restore_location.clone();

                if ctx.received_configuration_done {
                    if let Some(to_stable_sender) = ctx.to_stable_sender.clone() {
                        to_stable_sender.send(req.clone())?;
                    }
                }
            }
            info!(
                "received launch; configuration done? {0:?}; req: {1:?}",
                ctx.received_configuration_done, req
            );

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
            sender.send(resp)?;
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
            sender.send(resp)?;

            // TODO: log this when logging logic is properly abstracted
            info!(
                "configuration done sent response; launch_request: {:?}",
                ctx.launch_request,
            );
            if let Some(launch_request) = ctx.launch_request.clone() {
                if let Some(to_stable_sender) = ctx.to_stable_sender.clone() {
                    to_stable_sender.send(launch_request)?;
                }
            }
        }
        DapMessage::Request(req) if req.command == "disconnect" => {
            // let args: dap_types::DisconnectArguments = req.load_args()?;
            // h.dap_client.seq = ctx.seq;
            // h.respond_to_disconnect(req.clone(), args)?;
            let response_body = dap::DisconnectResponseBody {};
            // copied from `respond_dap` from handler.rs
            let response = DapMessage::Response(dap::Response {
                base: dap::ProtocolMessage {
                    seq: ctx.seq,
                    type_: "response".to_string(),
                },
                request_seq: req.base.seq,
                success: true,
                command: req.command.clone(),
                message: None,
                body: serde_json::to_value(response_body)?,
            });
            ctx.write_dap_messages(sender, &[response])?;

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
        DapMessage::Request(req) => {
            if let Some(to_stable_sender) = ctx.to_stable_sender.clone() {
                to_stable_sender.send(req.clone())?;
            }
        }
        _ => {}
    }

    Ok(())
}

fn task_thread(
    name: &str,
    from_thread_receiver: Receiver<dap::Request>,
    sender: Sender<DapMessage>,
    ctx_with_cached_launch: &Ctx,
    cached_launch: bool,
    run_to_entry: bool,
) -> Result<(), Box<dyn Error>> {
    let mut handler = if cached_launch {
        let for_launch = false;
        setup(
            &ctx_with_cached_launch.launch_trace_folder,
            &ctx_with_cached_launch.launch_trace_file,
            ctx_with_cached_launch.launch_raw_diff_index.clone(),
            &ctx_with_cached_launch.ct_rr_worker_exe,
            ctx_with_cached_launch.restore_location.clone(),
            sender.clone(),
            for_launch,
            name,
        )
        .map_err(|e| {
            error!("launch error: {e:?}");
            format!("launch error: {e:?}")
        })?
    } else {
        // `.initialized` is false
        Handler::new(
            TraceKind::DB,
            CtRRArgs {
                name: name.to_string(),
                ..CtRRArgs::default()
            },
            Box::new(Db::new(&PathBuf::from(""))),
        )
    };

    loop {
        info!("waiting for new message from DAP server");
        let request = from_thread_receiver.recv().map_err(|e| {
            error!("{name} thread recv error: {e:?}");
            format!("{name} thread recv error: {e:?}")
        })?;

        info!("  try to handle {:?}", request.command);
        if request.command == "launch" {
            let args = request.load_args::<dap::LaunchRequestArguments>()?;
            if let Some(folder) = &args.trace_folder {
                let launch_trace_folder = folder.clone();
                let launch_trace_file = if let Some(trace_file) = &args.trace_file {
                    trace_file.clone()
                } else {
                    "trace.json".into()
                };

                info!("stored launch trace folder: {0:?}", launch_trace_folder);

                let launch_raw_diff_index = args.raw_diff_index.clone();
                let ct_rr_worker_exe = args.ct_rr_worker_exe.unwrap_or(PathBuf::from("")); // unwrap_or(PathBuf::from(""));
                let restore_location = args.restore_location.clone();

                let for_launch = run_to_entry;
                handler = setup(
                    &launch_trace_folder,
                    &launch_trace_file,
                    launch_raw_diff_index.clone(),
                    &ct_rr_worker_exe,
                    restore_location,
                    sender.clone(),
                    for_launch,
                    name,
                )
                .map_err(|e| {
                    error!("launch error: {e:?}");
                    format!("launch error: {e:?}")
                })?;
            }
        } else {
            if handler.initialized {
                let res = handle_request(&mut handler, request, sender.clone());
                if let Err(e) = res {
                    warn!("  handle_request error in thread: {e:?}");
                    // continue with other request; trying to be more robust
                    // assuming it's for individual requests to fail
                    //   TODO: is it possible for some to leave bad state ?
                }
            }
        }
    }
    // Ok(())
}

#[cfg(feature = "io-transport")]
fn handle_client(
    receiver: Receiver<DapMessage>,
    is_stdio: bool,
    _receiving_thread: &thread::JoinHandle<Result<(), String>>,
    stream: Option<UnixStream>,
) -> Result<(), Box<dyn Error>> {
    use log::error;

    let mut ctx = Ctx::default();

    // TODO: start stable/other threads here

    let (sending_sender, sending_receiver) = mpsc::channel();

    let builder = thread::Builder::new().name("sending".to_string());
    let _sending_thread = builder.spawn(move || -> Result<(), String> {
        let mut send_seq = 0i64;
        let mut transport: Box<dyn DapTransport> = if is_stdio {
            Box::new(std::io::stdout())
        } else {
            Box::new(stream.expect("stream must be initialized if not stdio!"))
        };
        loop {
            info!("wait for next message from dap server/task threads");
            let msg: DapMessage = sending_receiver.recv().map_err(|e| {
                error!("sending thread: recv error: {e:?}");
                format!("sending thread: recv error: {e:?}")
            })?;
            let msg_with_seq = patch_message_seq(&msg, send_seq);
            send_seq += 1;
            transport.send(&msg_with_seq).map_err(|e| {
                error!("transport send error: {e:}");
                format!("transport send error: {e:}")
            })?;
        }
    })?;

    let (to_stable_sender, from_stable_receiver) = mpsc::channel::<dap::Request>();
    ctx.to_stable_sender = Some(to_stable_sender);
    let stable_sending_sender = sending_sender.clone();
    let stable_ctx = ctx.clone();

    info!("create stable thread");
    let cached_launch = false;
    let run_to_entry = true;
    let builder = thread::Builder::new().name("stable".to_string());
    let _stable_thread_handle = builder.spawn(move || -> Result<(), String> {
        task_thread(
            "stable",
            from_stable_receiver,
            stable_sending_sender,
            &stable_ctx,
            cached_launch,
            run_to_entry,
        )
        .map_err(|e| {
            error!("task_thread error: {e:?}");
            format!("task_thread error: {e:?}")
        })?;
        Ok(())
    })?;

    // start flow here; send to it
    // or start new each time; send to it?

    let (to_flow_sender, from_flow_receiver) = mpsc::channel::<dap::Request>();
    ctx.to_flow_sender = Some(to_flow_sender);
    let flow_sending_sender = sending_sender.clone();
    let flow_ctx = ctx.clone();

    info!("create flow thread");
    let cached_launch = false;
    let run_to_entry = false;
    let builder = thread::Builder::new().name("flow".to_string());
    let _flow_thread_handle = builder.spawn(move || -> Result<(), String> {
        task_thread(
            "flow",
            from_flow_receiver,
            flow_sending_sender,
            &flow_ctx,
            cached_launch,
            run_to_entry,
        )
        .map_err(|e| {
            error!("task_thread error: {e:?}");
            format!("task_thread error: {e:?}")
        })?;
        Ok(())
    })?;

    let (to_tracepoint_sender, from_tracepoint_receiver) = mpsc::channel::<dap::Request>();
    ctx.to_tracepoint_sender = Some(to_tracepoint_sender);
    let tracepoint_sending_sender = sending_sender.clone();
    let tracepoint_ctx = ctx.clone();

    info!("create tracepoint thread");
    let cached_launch = false;
    let run_to_entry = false;
    let builder = thread::Builder::new().name("tracepoint".to_string());
    let _tracepoint_thread_handle = builder.spawn(move || -> Result<(), String> {
        task_thread(
            "tracepoint",
            from_tracepoint_receiver,
            tracepoint_sending_sender,
            &tracepoint_ctx,
            cached_launch,
            run_to_entry,
        )
        .map_err(|e| {
            error!("task_thread error: {e:?}");
            format!("task_thread error: {e:?}")
        })?;
        Ok(())
    })?;

    loop {
        info!("waiting for new message from receiver");
        let msg = receiver.recv()?;
        // for now only handle requests here
        if let DapMessage::Request(request) = msg.clone() {
            // setups other worker threads
            if request.command == "launch" {
                if let Some(to_flow_sender) = ctx.to_flow_sender.clone() {
                    if let Err(e) = to_flow_sender.send(request.clone()) {
                        error!("flow send launch error: {e:?}");
                    }
                }

                if let Some(to_tracepoint_sender) = ctx.to_tracepoint_sender.clone() {
                    if let Err(e) = to_tracepoint_sender.send(request.clone()) {
                        error!("tracepoint send launch error: {e:?}");
                    }
                }
            }

            // handle all requests here: including `launch` from actually stable thread
            match request.command.as_str() {
                "ct/load-flow" => {
                    if let Some(to_flow_sender) = ctx.to_flow_sender.clone() {
                        if let Err(e) = to_flow_sender.send(request.clone()) {
                            error!("flow send request error: {e:?}");
                        }
                    }
                }
                "ct/event-load"
                | "ct/run-tracepoints"
                | "ct/setup-trace-session"
                | "ct/update-table"
                | "ct/load-terminal"
                | "ct/tracepoint-toggle"
                | "ct/tracepoint-delete"
                | "ct/load-history" => {
                    // TODO: separate load-history
                    if let Some(to_tracepoint_sender) = ctx.to_tracepoint_sender.clone() {
                        if let Err(e) = to_tracepoint_sender.send(request.clone()) {
                            error!("tracepoint send request error: {e:?}");
                        }
                    }
                }
                _ => {
                    // processes or sends to stable
                    // including `launch` again
                    let res = handle_message(&msg, sending_sender.clone(), &mut ctx);
                    if let Err(e) = res {
                        error!("handle_message error: {e:?}");
                    }
                }
            }
        }
    }

    // for now, we're just looping so this place is unreachable anyway:
    //   no need to `join`
    // still: TODO: think of when receiving a signal, do we need some special handling?

    // let _ = sending_thread.join().expect("can join the sending thread");
    // Ok(())
}
