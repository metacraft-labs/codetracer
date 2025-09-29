use std::error::Error;
use std::io::Write;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;

use log::info;

use crate::query::CtRRQuery;

#[derive(Debug)]
pub struct RRDispatcher {
    pub stable: CtRRWorker,
    pub ct_rr_worker_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
}

#[derive(Debug)]
pub struct CtRRWorker {
    pub name: String,
    pub active: bool,
    pub ct_rr_worker_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
    process: Option<Child>,
}

#[derive(Default)]
pub struct CtRRArgs {
    pub worker_exe: PathBuf,
    pub rr_trace_folder: PathBuf,
}

impl CtRRWorker {
    pub fn new(name: &str, ct_rr_worker_exe: &Path, rr_trace_folder: &Path) -> CtRRWorker {
        CtRRWorker {
            name: name.to_string(),
            active: false,
            ct_rr_worker_exe: PathBuf::from(ct_rr_worker_exe),
            rr_trace_folder: PathBuf::from(rr_trace_folder),
            process: None,
        }
    }

    pub fn start(&mut self) -> Result<(), Box<dyn Error>> {
        info!(
            "start: {} --name {} replay {}",
            self.ct_rr_worker_exe.display(),
            self.name,
            self.rr_trace_folder.display()
        );
        let ct_worker = Command::new(&self.ct_rr_worker_exe)
            .arg("replay")
            .arg("--name")
            .arg(&self.name)
            .arg(&self.rr_trace_folder)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?;

        self.process = Some(ct_worker);
        thread::sleep_ms(1_000);
        self.active = true;
        Ok(())
    }

    // for now: don't return a typed value here, only ok or an error
    pub fn run_query(&mut self, query: CtRRQuery) -> Result<(), Box<dyn Error>> {
        let mut stdin = self
            .process
            .as_mut()
            .expect("valid process")
            .stdin
            .take()
            .expect("stdin: TODO error");
        let mut stdout = self
            .process
            .as_mut()
            .expect("valid process")
            .stdout
            .take()
            .expect("stdout: TODO error");

        let raw_json = serde_json::to_string(&query)?;
        let reader = BufReader::new(stdout);

        info!("send to worker {raw_json}\n");
        write!(stdin, "{}\n", raw_json)?;

        let mut res = "".to_string();
        info!("wait to read");

        for line_result in reader.lines() {
            info!("line_result {line_result:?}");
            if let Ok(line) = line_result {
                res.push_str(&line);
                res.push_str("\n");
            } else {
                continue;
            }
        }
        info!("res {res}");
        if res == "ok" {
            Ok(())
        } else {
            Err(format!("run_query ct rr worker error: {}", res).into())
        }
    }
}

impl RRDispatcher {
    pub fn new(ct_rr_args: CtRRArgs) -> RRDispatcher {
        RRDispatcher {
            stable: CtRRWorker::new("stable", &ct_rr_args.worker_exe, &ct_rr_args.rr_trace_folder),
            ct_rr_worker_exe: ct_rr_args.worker_exe.clone(),
            rr_trace_folder: ct_rr_args.rr_trace_folder.clone(),
        }
    }

    pub fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        self.stable.run_query(CtRRQuery::RunToEntry)
    }

    pub fn ensure_active_stable(&mut self) -> Result<(), Box<dyn Error>> {
        // start stable process if not active, store fields, setup ipc? store in stable
        if !self.stable.active {
            self.stable.start()?;
        }
        // check again:
        if !self.stable.active {
            return Err("stable started, but still not active without an obvious error".into());
        }

        Ok(())
    }
}
