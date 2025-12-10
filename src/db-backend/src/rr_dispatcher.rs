use std::error::Error;
use std::io::Write;
use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::thread;
use std::time::Duration;

use log::{debug, error, info, warn};
use runtime_tracing::StepId;

use crate::db::DbRecordEvent;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
use crate::paths::ct_rr_worker_socket_path;
use crate::query::CtRRQuery;
use crate::replay::Replay;
use crate::task::{
    Action, Breakpoint, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg, Location,
    ProgramEvent, VariableWithRecord,
};
use crate::value::ValueRecordWithType;

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
    stream: Option<UnixStream>,
}

#[derive(Default, Debug, Clone)]
pub struct CtRRArgs {
    pub worker_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
    pub name: String,
}

impl CtRRWorker {
    pub fn new(name: &str, index: usize, ct_rr_worker_exe: &Path, rr_trace_folder: &Path) -> CtRRWorker {
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

        self.process = Some(ct_worker);
        self.setup_worker_sockets()?;
        self.active = true;
        Ok(())
    }

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

        thread::sleep(Duration::from_millis(800));

        info!("try to connect to worker with socket in {}", socket_path.display());
        loop {
            if let Ok(stream) = UnixStream::connect(&socket_path) {
                self.stream = Some(stream);
                break;
            }
            thread::sleep(Duration::from_millis(1));
            // TODO: handle different kinds of errors

            // TODO: after some retries, assume a problem and return an error?
        }

        Ok(())
    }

    // for now: don't return a typed value here, only Ok(raw value) or an error
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

        if !res.starts_with("error:") {
            Ok(res)
        } else {
            Err(format!("run_query ct rr worker error: {}", res).into())
        }
    }
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
                return Err(e.into());
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

    fn current_step_id(&mut self) -> StepId {
        // cache location or step_id and return
        // OR always load from worker
        // TODO: return result or do something else or cache ?
        let location = self.load_location_directly().expect("access to step_id");
        StepId(location.rr_ticks.0)
    }

    fn tracepoint_jump(&mut self, event: &ProgramEvent) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        self.stable
            .run_query(CtRRQuery::TracepointJump { event: event.clone() })?;
        Ok(())
    }
}
