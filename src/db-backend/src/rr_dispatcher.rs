use std::error::Error;
use std::io::Write;
use std::io::{BufRead, BufReader};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(windows)]
use std::net::TcpStream;

use log::{debug, error, info, warn};
use runtime_tracing::StepId;
use serde::Deserialize;

use crate::db::DbRecordEvent;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
#[cfg(unix)]
use crate::paths::ct_rr_worker_socket_path;
#[cfg(windows)]
use crate::paths::CODETRACER_PATHS;
use crate::query::{
    CtRRQuery, TtdTracepointEvalRequest, TtdTracepointEvalResponseEnvelope, TtdTracepointEvalMode,
    TtdTracepointFunctionCallRequest,
};
use crate::replay::Replay;
use crate::task::{
    Action, Breakpoint, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg, Location,
    ProgramEvent, VariableWithRecord, NO_STEP_ID,
};
use crate::value::ValueRecordWithType;
use runtime_tracing::{TypeKind, TypeRecord, TypeSpecificInfo};

#[cfg(unix)]
type WorkerStream = UnixStream;

#[cfg(windows)]
type WorkerStream = TcpStream;

#[cfg(not(any(unix, windows)))]
type WorkerStream = ();

#[derive(Debug)]
pub struct RRDispatcher {
    pub stable: CtRRWorker,
    pub ct_rr_worker_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
    pub name: String,
    pub index: usize,
}

#[derive(Debug)]
pub struct CtRRWorker {
    pub name: String,
    pub index: usize,
    pub active: bool,
    pub ct_rr_worker_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
    process: Option<Child>,
    stream: Option<WorkerStream>,
}

#[derive(Default, Debug, Clone)]
pub struct CtRRArgs {
    pub worker_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
    pub name: String,
}

#[derive(Debug, Deserialize)]
struct WorkerTransportEndpoint {
    transport: String,
    address: String,
}

impl CtRRWorker {
    pub fn new(name: &str, index: usize, ct_rr_worker_exe: &Path, rr_trace_folder: &Path) -> CtRRWorker {
        info!("new replay {name} {index}");
        CtRRWorker {
            name: name.to_string(),
            index,
            active: false,
            ct_rr_worker_exe: PathBuf::from(ct_rr_worker_exe),
            rr_trace_folder: PathBuf::from(rr_trace_folder),
            process: None,
            stream: None,
        }
    }

    pub fn start(&mut self) -> Result<(), Box<dyn Error>> {
        info!(
            "start: {} replay-worker --name {} --index {} {}",
            self.ct_rr_worker_exe.display(),
            self.name,
            self.index,
            self.rr_trace_folder.display()
        );

        let ct_worker = Command::new(&self.ct_rr_worker_exe)
            .arg("replay-worker")
            .arg("--name")
            .arg(&self.name)
            .arg("--index")
            .arg(self.index.to_string())
            .arg(&self.rr_trace_folder)
            .spawn()?;

        let worker_pid = ct_worker.id();
        self.process = Some(ct_worker);
        if let Err(err) = self.setup_worker_sockets() {
            if let Some(child) = self.process.as_mut() {
                let _ = child.kill();
                let _ = child.wait();
            }
            self.process = None;
            self.stream = None;
            self.active = false;
            return Err(format!(
                "failed to initialize replay-worker transport for pid {}: {}",
                worker_pid, err
            )
            .into());
        }
        self.active = true;
        Ok(())
    }

    #[cfg(unix)]
    fn setup_worker_sockets(&mut self) -> Result<(), Box<dyn Error>> {
        // assuming that the ct rr worker creates the sockets!
        // code copied and adapted from `connect_socket_with_backend_and_loop` in ct-rr-worker
        //   which is itself copied/adapted/written from/based on https://emmanuelbosquet.com/2022/whatsaunixsocket/

        let run_id = std::process::id() as usize;

        // let tmp_path: PathBuf = { CODETRACER_PATHS.lock()?.tmp_path.clone() };
        // let run_dir = run_dir_for(&tmp_path, run_id)?;
        // // remove_dir_all(&run_dir)?;
        // create_dir_all(&run_dir)?;

        let socket_path = ct_rr_worker_socket_path("", &self.name, self.index, run_id)?;

        // for a while it was enabled because of some problems with socket setup
        //   but i think we resolved them with fixing another deadlock sender bug
        //   and maybe it wasn't connected to waiting here
        // i might be wrong, so leaving this for a reminder; sleeping is flakey in most cases though
        thread::sleep(Duration::from_millis(800));

        info!("try to connect to worker with socket in {}", socket_path.display());
        loop {
            if let Ok(stream) = UnixStream::connect(&socket_path) {
                self.stream = Some(stream);
                info!("stream is now setup");
                break;
            }
            thread::sleep(Duration::from_millis(1));
            // TODO: handle different kinds of errors

            // TODO: after some retries, assume a problem and return an error?
        }

        Ok(())
    }

    #[cfg(windows)]
    fn setup_worker_sockets(&mut self) -> Result<(), Box<dyn Error>> {
        let deadline = Instant::now() + Duration::from_secs(10);
        let poll_interval = Duration::from_millis(25);
        let mut last_error: Option<String> = None;
        let manifest_name = format!("ct_rr_support_{}_{}_from_.sock", self.name, self.index);
        let worker_pid = self.process.as_ref().map(std::process::Child::id);
        let tmp_path = {
            CODETRACER_PATHS
                .lock()
                .map_err(|e| format!("failed to lock CODETRACER_PATHS: {e}"))?
                .tmp_path
                .clone()
        };
        info!("try to resolve worker endpoint manifest for replay worker: {}", manifest_name);

        while Instant::now() < deadline {
            if let Some(pid) = worker_pid {
                let preferred_manifest = tmp_path.join(format!("run-{}", pid)).join(&manifest_name);
                if preferred_manifest.exists() {
                    match std::fs::read_to_string(&preferred_manifest) {
                        Ok(payload) => {
                            let endpoint = match serde_json::from_str::<WorkerTransportEndpoint>(&payload) {
                                Ok(endpoint) => endpoint,
                                Err(err) => {
                                    last_error = Some(format!(
                                        "failed to parse worker endpoint manifest {}: {err}",
                                        preferred_manifest.display()
                                    ));
                                    thread::sleep(poll_interval);
                                    continue;
                                }
                            };

                            if endpoint.transport != "tcp" {
                                last_error = Some(format!(
                                    "unsupported worker transport '{}' in manifest {}; expected 'tcp'",
                                    endpoint.transport,
                                    preferred_manifest.display()
                                ));
                                thread::sleep(poll_interval);
                                continue;
                            }
                            if endpoint.address.trim().is_empty() {
                                last_error = Some(format!(
                                    "worker endpoint manifest {} has empty tcp address",
                                    preferred_manifest.display()
                                ));
                                thread::sleep(poll_interval);
                                continue;
                            }

                            match connect_tcp_endpoint_with_timeout(&endpoint.address, Duration::from_millis(250)) {
                                Ok(stream) => {
                                    self.stream = Some(stream);
                                    info!(
                                        "worker stream is now setup via tcp {} using preferred manifest {}",
                                        endpoint.address,
                                        preferred_manifest.display()
                                    );
                                    return Ok(());
                                }
                                Err(err) => {
                                    last_error = Some(format!(
                                        "failed connecting to replay-worker tcp endpoint {} from preferred manifest {}: {}",
                                        endpoint.address,
                                        preferred_manifest.display(),
                                        err
                                    ));
                                }
                            }
                        }
                        Err(err) => {
                            last_error = Some(format!(
                                "failed reading worker endpoint manifest {}: {}",
                                preferred_manifest.display(),
                                err
                            ));
                        }
                    }
                }
                thread::sleep(poll_interval);
                continue;
            }

            let mut candidates = Vec::new();
            if let Ok(run_dirs) = std::fs::read_dir(&tmp_path) {
                for run_dir in run_dirs.flatten() {
                    let path = run_dir.path();
                    if !path.is_dir() {
                        continue;
                    }
                    let Some(run_name) = path.file_name().and_then(|n| n.to_str()) else {
                        continue;
                    };
                    if !run_name.starts_with("run-") {
                        continue;
                    }
                    if let Some(pid) = worker_pid {
                        if run_name == format!("run-{}", pid) {
                            continue;
                        }
                    }
                    let manifest_path = path.join(&manifest_name);
                    if manifest_path.exists() {
                        let modified = std::fs::metadata(&manifest_path)
                            .and_then(|m| m.modified())
                            .ok();
                        candidates.push((manifest_path, modified));
                    }
                }
            }

            candidates.sort_by(|a, b| b.1.cmp(&a.1));

            for (manifest_path, _) in candidates {
                match std::fs::read_to_string(&manifest_path) {
                    Ok(payload) => {
                        let endpoint = match serde_json::from_str::<WorkerTransportEndpoint>(&payload) {
                            Ok(endpoint) => endpoint,
                            Err(err) => {
                                last_error = Some(format!(
                                    "failed to parse worker endpoint manifest {}: {err}",
                                    manifest_path.display()
                                ));
                                continue;
                            }
                        };

                        if endpoint.transport != "tcp" {
                            last_error = Some(format!(
                                "unsupported worker transport '{}' in manifest {}; expected 'tcp'",
                                endpoint.transport,
                                manifest_path.display()
                            ));
                            continue;
                        }
                        if endpoint.address.trim().is_empty() {
                            last_error = Some(format!(
                                "worker endpoint manifest {} has empty tcp address",
                                manifest_path.display()
                            ));
                            continue;
                        }

                        match connect_tcp_endpoint_with_timeout(&endpoint.address, Duration::from_millis(250)) {
                            Ok(stream) => {
                                self.stream = Some(stream);
                                info!(
                                    "worker stream is now setup via tcp {} using manifest {}",
                                    endpoint.address,
                                    manifest_path.display()
                                );
                                return Ok(());
                            }
                            Err(err) => {
                                last_error = Some(format!(
                                    "failed connecting to replay-worker tcp endpoint {} from manifest {}: {}",
                                    endpoint.address,
                                    manifest_path.display(),
                                    err
                                ));
                            }
                        }
                    }
                    Err(err) => {
                        last_error = Some(format!(
                            "failed reading worker endpoint manifest {}: {}",
                            manifest_path.display(),
                            err
                        ));
                    }
                }
            }
            thread::sleep(poll_interval);
        }

        Err(last_error
            .unwrap_or_else(|| {
                format!(
                    "timed out waiting for replay-worker endpoint manifest '{}' under {}",
                    manifest_name,
                    tmp_path.display()
                )
            })
            .into())
    }

    #[cfg(not(any(unix, windows)))]
    fn setup_worker_sockets(&mut self) -> Result<(), Box<dyn Error>> {
        Err("ct-rr worker transport is only supported on Unix and Windows platforms".into())
    }

    // for now: don't return a typed value here, only Ok(raw value) or an error
    #[allow(clippy::expect_used)] // stream must be initialized before run_query is called
    #[cfg(any(unix, windows))]
    pub fn run_query(&mut self, query: CtRRQuery) -> Result<String, Box<dyn Error>> {
        let raw_json = serde_json::to_string(&query)?;

        debug!("send to worker {raw_json}\n");
        self.stream
            .as_mut()
            .expect("valid sending stream")
            .write_all(&format!("{raw_json}\n").into_bytes())?;
        // `clippy::unused_io_amount` catched we need write_all, not write

        let mut res = "".to_string();
        debug!("wait to read");

        let mut reader = BufReader::new(self.stream.as_mut().expect("valid receiving stream"));
        reader.read_line(&mut res)?; // TODO: more robust reading/read all

        res = String::from(res.trim()); // trim newlines/whitespace!

        debug!("res: `{res}`");

        if res.is_empty() {
            // EOF — the replay worker crashed or disconnected. Mark the
            // worker as inactive so that the next query attempt can restart it,
            // and return a clear error rather than an empty string that would
            // fail JSON parsing downstream.
            self.active = false;
            return Err("ct-rr-support replay worker disconnected (EOF on response)".into());
        }

        if !res.starts_with("error:") {
            Ok(res)
        } else {
            Err(format!("run_query ct rr worker error: {}", res).into())
        }
    }

    #[cfg(not(any(unix, windows)))]
    pub fn run_query(&mut self, _query: CtRRQuery) -> Result<String, Box<dyn Error>> {
        Err("ct-rr worker transport is only supported on Unix and Windows platforms".into())
    }
}

impl Drop for CtRRWorker {
    fn drop(&mut self) {
        self.stream = None;
        if let Some(child) = self.process.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.process = None;
        self.active = false;
    }
}

#[cfg(windows)]
fn connect_tcp_endpoint_with_timeout(address: &str, timeout: Duration) -> Result<TcpStream, Box<dyn Error>> {
    use std::net::ToSocketAddrs;

    let mut last_error: Option<String> = None;
    for resolved in address
        .to_socket_addrs()
        .map_err(|e| format!("failed to resolve replay-worker endpoint '{address}': {e}"))?
    {
        match TcpStream::connect_timeout(&resolved, timeout) {
            Ok(stream) => return Ok(stream),
            Err(err) => {
                last_error = Some(format!("{} ({})", resolved, err));
            }
        }
    }

    Err(last_error
        .unwrap_or_else(|| format!("no socket addresses resolved for replay-worker endpoint '{address}'"))
        .into())
}

impl RRDispatcher {
    pub fn new(name: &str, index: usize, ct_rr_args: CtRRArgs) -> RRDispatcher {
        RRDispatcher {
            name: name.to_string(),
            index,
            stable: CtRRWorker::new(name, index, &ct_rr_args.worker_exe, &ct_rr_args.rr_trace_folder),
            ct_rr_worker_exe: ct_rr_args.worker_exe.clone(),
            rr_trace_folder: ct_rr_args.rr_trace_folder.clone(),
        }
    }

    pub fn ensure_active_stable(&mut self) -> Result<(), Box<dyn Error>> {
        // start stable process if not active, store fields, setup ipc? store in stable
        if !self.stable.active {
            let res = self.stable.start();
            if let Err(e) = res {
                error!("can't start ct rr worker for {}! error is {:?}", self.name, e);
                return Err(e);
            }
        }
        // check again:
        if !self.stable.active {
            return Err("stable started, but still not active without an obvious error".into());
        }

        Ok(())
    }

    fn load_location_directly(&mut self) -> Result<Location, Box<dyn Error>> {
        Ok(serde_json::from_str::<Location>(
            &self.stable.run_query(CtRRQuery::LoadLocation)?,
        )?)
    }
}

impl Replay for RRDispatcher {
    fn load_location(&mut self, _expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
        self.ensure_active_stable()?;
        self.load_location_directly()
    }

    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        let _ok = self.stable.run_query(CtRRQuery::RunToEntry)?;
        Ok(())
    }

    fn load_events(&mut self) -> Result<Events, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let events = serde_json::from_str::<Events>(&self.stable.run_query(CtRRQuery::LoadAllEvents)?)?;
        Ok(events)
        // Ok(Events {
        //     events: vec![],
        //     first_events: vec![],
        //     contents: "".to_string(),
        // })
    }

    fn step(&mut self, action: Action, forward: bool) -> Result<bool, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<bool>(&self.stable.run_query(CtRRQuery::Step { action, forward })?)?;
        Ok(res)
    }

    fn load_locals(&mut self, arg: CtLoadLocalsArguments) -> Result<Vec<VariableWithRecord>, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res =
            serde_json::from_str::<Vec<VariableWithRecord>>(&self.stable.run_query(CtRRQuery::LoadLocals { arg })?)?;
        Ok(res)
    }

    fn load_value(
        &mut self,
        expression: &str,
        depth_limit: Option<usize>,
        lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<ValueRecordWithType>(&self.stable.run_query(CtRRQuery::LoadValue {
            expression: expression.to_string(),
            depth_limit,
            lang,
        })?)?;
        Ok(res)
    }

    fn load_return_value(
        &mut self,
        depth_limit: Option<usize>,
        lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<ValueRecordWithType>(
            &self
                .stable
                .run_query(CtRRQuery::LoadReturnValue { depth_limit, lang })?,
        )?;
        Ok(res)
    }

    fn load_step_events(&mut self, _step_id: StepId, _exact: bool) -> Vec<DbRecordEvent> {
        // TODO: maybe cache events directly in replay for now, and use the same logic for them as in Db?
        // or directly embed Db? or separate events in a separate EventList?
        warn!("load_step_events not implemented for rr traces");
        vec![]
    }

    fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<Vec<CallLine>>(&self.stable.run_query(CtRRQuery::LoadCallstack)?)?;
        Ok(res)
    }

    fn load_history(&mut self, arg: &LoadHistoryArg) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>> {
        self.ensure_active_stable()?;
        let res = serde_json::from_str::<(Vec<HistoryResultWithRecord>, i64)>(
            &self.stable.run_query(CtRRQuery::LoadHistory { arg: arg.clone() })?,
        )?;
        Ok(res)
    }

    fn jump_to(&mut self, _step_id: StepId) -> Result<bool, Box<dyn Error>> {
        // TODO
        error!("TODO rr jump_to: for now run to entry");
        self.run_to_entry()?;
        Ok(true)
        // todo!()
    }

    fn location_jump(&mut self, location: &Location) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        let _ = self.stable.run_query(CtRRQuery::LocationJump {
            location: location.clone(),
        })?;
        Ok(())
    }

    fn add_breakpoint(&mut self, path: &str, line: i64) -> Result<Breakpoint, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let breakpoint = serde_json::from_str::<Breakpoint>(&self.stable.run_query(CtRRQuery::AddBreakpoint {
            path: path.to_string(),
            line,
        })?)?;
        Ok(breakpoint)
    }

    fn delete_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>> {
        self.ensure_active_stable()?;
        Ok(serde_json::from_str::<bool>(&self.stable.run_query(
            CtRRQuery::DeleteBreakpoint {
                breakpoint: breakpoint.clone(),
            },
        )?)?)
    }

    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>> {
        self.ensure_active_stable()?;
        Ok(serde_json::from_str::<bool>(
            &self.stable.run_query(CtRRQuery::DeleteBreakpoints)?,
        )?)
    }

    fn toggle_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn Error>> {
        self.ensure_active_stable()?;
        Ok(serde_json::from_str::<Breakpoint>(&self.stable.run_query(
            CtRRQuery::ToggleBreakpoint {
                breakpoint: breakpoint.clone(),
            },
        )?)?)
    }

    fn enable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        let _ = self.stable.run_query(CtRRQuery::EnableBreakpoints)?;
        Ok(())
    }

    fn disable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        let _ = self.stable.run_query(CtRRQuery::DisableBreakpoints)?;
        Ok(())
    }

    fn jump_to_call(&mut self, location: &Location) -> Result<Location, Box<dyn Error>> {
        self.ensure_active_stable()?;
        Ok(serde_json::from_str::<Location>(&self.stable.run_query(
            CtRRQuery::JumpToCall {
                location: location.clone(),
            },
        )?)?)
    }

    fn event_jump(&mut self, event: &ProgramEvent) -> Result<bool, Box<dyn Error>> {
        self.ensure_active_stable()?;
        Ok(serde_json::from_str::<bool>(&self.stable.run_query(
            CtRRQuery::EventJump {
                program_event: event.clone(),
            },
        )?)?)
    }

    fn callstack_jump(&mut self, depth: usize) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        self.stable.run_query(CtRRQuery::CallstackJump { depth })?;
        Ok(())
    }

    #[allow(clippy::expect_used)] // load_location_directly should succeed after ensure_active_stable
    fn current_step_id(&mut self) -> StepId {
        // cache location or step_id and return
        // OR always load from worker
        // TODO: return result or do something else or cache ?
        match self.ensure_active_stable() {
            Ok(_) => {
                let location = self.load_location_directly().expect("access to step_id");
                StepId(location.rr_ticks.0)
            }
            Err(e) => {
                error!("current_step_id: can't ensure active worker: error: {e:?}");
                // hard to change all callsites to handle result for now
                //   but not sure if NO_STEP_ID is much better: however this is only for rr cases
                //   so we *should* try to not directly index into db.steps with it even if not NO_STEP_ID?
                error!("  for now returning NO_STEP_ID");
                StepId(NO_STEP_ID)
            }
        }
    }

    fn tracepoint_jump(&mut self, event: &ProgramEvent) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        self.stable
            .run_query(CtRRQuery::TracepointJump { event: event.clone() })?;
        Ok(())
    }

    fn evaluate_call_expression(
        &mut self,
        call_expression: &str,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        self.ensure_active_stable()?;
        let request = TtdTracepointEvalRequest {
            mode: TtdTracepointEvalMode::EmulatedFunction,
            expression: None,
            function_call: Some(TtdTracepointFunctionCallRequest {
                target_expression: String::new(),
                call_expression: Some(call_expression.to_string()),
                signature: None,
                arguments: vec![],
                return_address: None,
            }),
        };

        let response_json = self
            .stable
            .run_query(CtRRQuery::TtdTracepointEvaluate { request })?;
        let response: TtdTracepointEvalResponseEnvelope = serde_json::from_str(&response_json)?;

        if let Some(diag) = response.diagnostic {
            return Err(format!(
                "tracepoint call evaluation failed: {}{}",
                diag.message,
                diag.detail
                    .as_ref()
                    .map(|detail| format!(" ({detail})"))
                    .unwrap_or_default()
            )
            .into());
        }

        if let Some(value) = tracepoint_response_value(&response) {
            return Ok(value);
        }

        Err("tracepoint call evaluation did not return a value".into())
    }
}

fn tracepoint_response_value(
    response: &TtdTracepointEvalResponseEnvelope,
) -> Option<ValueRecordWithType> {
    response
        .value
        .clone()
        .or_else(|| response.return_value.clone())
        .or_else(|| tracepoint_return_value_from_class(response))
}

fn tracepoint_return_value_from_class(
    response: &TtdTracepointEvalResponseEnvelope,
) -> Option<ValueRecordWithType> {
    let raw = response.return_value_u64?;
    let class = response
        .return_value_class
        .unwrap_or(TtdTracepointValueClass::U64);

    let (kind, lang_type) = match class {
        TtdTracepointValueClass::Void => return None,
        TtdTracepointValueClass::Bool => (TypeKind::Bool, "bool"),
        TtdTracepointValueClass::I64 => (TypeKind::Int, "i64"),
        TtdTracepointValueClass::U64 => (TypeKind::Int, "u64"),
        TtdTracepointValueClass::Pointer => (TypeKind::Raw, "pointer"),
    };

    let typ = TypeRecord {
        kind,
        lang_type: lang_type.to_string(),
        specific_info: TypeSpecificInfo::None,
    };

    Some(match class {
        TtdTracepointValueClass::Void => return None,
        TtdTracepointValueClass::Bool => ValueRecordWithType::Bool {
            b: raw != 0,
            typ,
        },
        TtdTracepointValueClass::I64 => {
            let signed = i64::from_ne_bytes(raw.to_ne_bytes());
            ValueRecordWithType::Int { i: signed, typ }
        }
        TtdTracepointValueClass::U64 => ValueRecordWithType::Int {
            i: raw as i64,
            typ,
        },
        TtdTracepointValueClass::Pointer => ValueRecordWithType::Raw {
            r: format!("0x{raw:016x}"),
            typ,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use runtime_tracing::{TypeSpecificInfo, TypeRecord, TypeKind};

    #[test]
    fn tracepoint_return_value_prefers_complex_payload() {
        let typ = TypeRecord {
            kind: TypeKind::Struct,
            lang_type: "Pair".to_string(),
            specific_info: TypeSpecificInfo::Struct {
                fields: vec![],
            },
        };
        let complex = ValueRecordWithType::Struct {
            field_values: vec![],
            typ: typ.clone(),
        };
        let response = TtdTracepointEvalResponseEnvelope {
            mode: TtdTracepointEvalMode::EmulatedFunction,
            replay_state_preserved: true,
            value: None,
            return_value: Some(complex.clone()),
            return_value_class: Some(TtdTracepointValueClass::U64),
            return_value_u64: Some(123),
            invocation: None,
            diagnostic: None,
        };

        let derived = tracepoint_response_value(&response).expect("value");
        assert_eq!(derived, complex);
    }

    #[test]
    fn tracepoint_return_value_bool() {
        let response = TtdTracepointEvalResponseEnvelope {
            mode: TtdTracepointEvalMode::EmulatedFunction,
            replay_state_preserved: true,
            value: None,
            return_value: None,
            return_value_class: Some(TtdTracepointValueClass::Bool),
            return_value_u64: Some(1),
            invocation: None,
            diagnostic: None,
        };

        let value = tracepoint_return_value_from_class(&response).expect("bool value");
        match value {
            ValueRecordWithType::Bool { b, .. } => assert!(b),
            other => panic!("unexpected value type: {other:?}"),
        }
    }

    #[test]
    fn tracepoint_return_value_i64() {
        let response = TtdTracepointEvalResponseEnvelope {
            mode: TtdTracepointEvalMode::EmulatedFunction,
            replay_state_preserved: true,
            value: None,
            return_value: None,
            return_value_class: Some(TtdTracepointValueClass::I64),
            return_value_u64: Some(u64::MAX),
            invocation: None,
            diagnostic: None,
        };

        let value = tracepoint_return_value_from_class(&response).expect("i64 value");
        match value {
            ValueRecordWithType::Int { i, .. } => assert_eq!(i, -1),
            other => panic!("unexpected value type: {other:?}"),
        }
    }

    #[test]
    fn tracepoint_return_value_pointer() {
        let response = TtdTracepointEvalResponseEnvelope {
            mode: TtdTracepointEvalMode::EmulatedFunction,
            replay_state_preserved: true,
            value: None,
            return_value: None,
            return_value_class: Some(TtdTracepointValueClass::Pointer),
            return_value_u64: Some(0x1234),
            invocation: None,
            diagnostic: None,
        };

        let value = tracepoint_return_value_from_class(&response).expect("pointer value");
        match value {
            ValueRecordWithType::Raw { r, .. } => assert_eq!(r, "0x0000000000001234"),
            other => panic!("unexpected value type: {other:?}"),
        }
    }
}
