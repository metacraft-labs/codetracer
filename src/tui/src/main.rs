// unused code
#![allow(dead_code)]

use std::env;
use std::error::Error;
use std::io::{self, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::str;

use crossterm::{
    cursor,
    event::KeyCode,
    execute, queue,
    style::{self, Stylize},
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use sqlite;
use tokio::signal;
use tokio::sync::mpsc;

extern crate num_derive;
use num_traits::FromPrimitive;

mod actions;
mod component;
mod core;
mod dap_client;
mod editor_component;
mod event;
mod lang;
mod panel;
mod state_component;
mod status_component;
mod task;
mod value;
mod window;

use crate::dap_client::DapClient;
use component::Component;
use core::{caller_process_pid, Core, CODETRACER_TMP_PATH};
use editor_component::EditorComponent;
use event::{CtEvent, Event};
use lang::Lang;
use panel::{coord, panel, size};
use serde_json::Value;
use state_component::StateComponent;
use status_component::StatusComponent;
use task::{Action, EventId, EventKind, FlowUpdate, Location, MoveState, StepArg, TaskKind};

#[derive(Debug, Default)]
pub struct Trace {
    id: i64,
    program: String,
    args: Vec<String>,
    env: String,
    workdir: String,
    output: String,
    source_folders: Vec<String>,
    low_level_folder: String,
    compile_command: String,
    output_folder: String,
    date: String,
    duration: String,
    lang: Lang,
    imported: bool,
}

#[derive(Debug)]
pub struct App {
    location: Location,
    status: String,
    trace: Trace,
    receiver: Option<UnixStream>,
    sender: Option<UnixStream>,
    caller_process_pid: u32,
    links_path: PathBuf,
    codetracer_exe_dir: PathBuf,
    core: Core,
    exit: bool,
    components: Vec<Box<dyn Component>>,
}

impl Default for App {
    fn default() -> Self {
        Self {
            location: Location::default(),
            status: String::new(),
            trace: Trace::default(),
            receiver: None,
            sender: None,
            caller_process_pid: 0,
            links_path: PathBuf::new(),
            codetracer_exe_dir: PathBuf::new(),
            core: Core::default(),
            exit: false,
            components: Vec::new(),
        }
    }
}

const CT_SOCKET_PATH: &str = "/tmp/ct_socket";
const CT_CLIENT_SOCKET_PATH: &str = "/tmp/ct_client_socket";

const EDITOR_COMPONENT: usize = 0;

impl App {
    fn init_components(&mut self) {
        self.components = vec![
            Box::new(EditorComponent::new(
                panel(coord(1, 1), size(120, 38)),
                "a.c",
            )),
            Box::new(StateComponent::new(panel(coord(122, 1), size(25, 38)))),
            Box::new(StatusComponent::new(
                panel(coord(1, 40), size(147, 2)),
                "starting..",
            )),
        ];
    }

    fn draw_layout(&mut self) -> Result<(), Box<dyn Error>> {
        let mut stdout = io::stdout();
        queue!(
            stdout,
            cursor::MoveTo(50, 0),
            style::PrintStyledContent(" trace ".blue())
        )?;

        for component in self.components.iter_mut() {
            component.render()?;
        }

        stdout.flush()?;
        Ok(())
    }

    fn parse_trace_record(&self, statement: &sqlite::Statement) -> Result<Trace, Box<dyn Error>> {
        let lang = FromPrimitive::from_i64(statement.read::<i64, _>("lang")?)
            .expect("expected valid lang");
        let trace = Trace {
            id: statement.read::<i64, _>("id")?,
            source_folders: str::split(&statement.read::<String, _>("sourceFolders")?, " ")
                .map(|p| p.to_string())
                .collect::<Vec<String>>(),
            program: statement.read::<String, _>("program")?,
            args: str::split(&statement.read::<String, _>("args")?, " ")
                .map(|p| p.to_string())
                .collect::<Vec<String>>(),
            env: statement.read::<String, _>("env")?,
            workdir: statement.read::<String, _>("workdir")?,
            output: statement.read::<String, _>("output")?,
            low_level_folder: statement.read::<String, _>("lowLevelFolder")?,
            compile_command: statement.read::<String, _>("compileCommand")?,
            output_folder: statement.read::<String, _>("outputFolder")?,
            date: statement.read::<String, _>("date")?,
            duration: "".to_string(),
            lang: lang,
            imported: statement.read::<i64, _>("imported")? == 1,
        };

        Ok(trace)
    }

    fn load_trace_from_program(&self, program_pattern: &str) -> Result<Trace, Box<dyn Error>> {
        let db_path = home::home_dir()
            .unwrap()
            .join(".local/share/codetracer/trace_index.db");
        let connection = sqlite::open(&db_path).unwrap();
        let query = "SELECT * FROM traces WHERE program LIKE ? ORDER BY id DESC LIMIT 1";
        // println!("query traces {}", db_path.display());

        let mut statement = connection.prepare(query).unwrap();
        let pattern = format!("%{program_pattern}%");
        let pattern_str = pattern.as_str();
        statement.bind((1, pattern_str)).unwrap();

        if let Ok(sqlite::State::Row) = statement.next() {
            return self.parse_trace_record(&statement);
        }
        Err(Box::new(std::io::Error::new(
            std::io::ErrorKind::Other,
            "sqlite loading trace error",
        )))
    }

    fn load_trace_from_folder(&self, folder: &str) -> Result<Trace, Box<dyn Error>> {
        #[derive(serde::Deserialize)]
        struct TraceMetadata {
            program: String,
            args: Vec<String>,
            workdir: String,
        }

        let metadata_path = PathBuf::from(folder).join("trace_metadata.json");
        let raw = std::fs::read_to_string(&metadata_path)?;
        let metadata: TraceMetadata = serde_json::from_str(&raw)?;

        Ok(Trace {
            id: -1,
            program: metadata.program,
            args: metadata.args,
            env: String::new(),
            workdir: metadata.workdir,
            output: String::new(),
            source_folders: vec![folder.to_string()],
            low_level_folder: String::new(),
            compile_command: String::new(),
            output_folder: folder.to_string(),
            date: String::new(),
            duration: String::new(),
            lang: Lang::RustWasm, // TODO
            imported: true,
        })
    }

    fn register_trace_in_db(&mut self) -> Result<(), Box<dyn Error>> {
        let db_path = home::home_dir()
            .ok_or("no home")?
            .join(".local/share/codetracer/trace_index.db");

        let connection = sqlite::open(&db_path)?;

        // check if trace already exists
        let mut check =
            connection.prepare("SELECT id FROM traces WHERE outputFolder = ? LIMIT 1")?;
        check.bind((1, self.trace.output_folder.as_str()))?;
        if let Ok(sqlite::State::Row) = check.next() {
            self.trace.id = check.read::<i64, _>(0)?;
            return Ok(());
        }

        // get next id
        let mut st = connection.prepare("SELECT maxTraceID FROM trace_values LIMIT 1")?;
        let new_id = if let Ok(sqlite::State::Row) = st.next() {
            st.read::<i64, _>(0)?
        } else {
            0
        } + 1;

        let mut update = connection.prepare("UPDATE trace_values SET maxTraceID = ? WHERE 1")?;
        update.bind((1, new_id))?;
        let _ = update.next()?;

        let args_joined = self.trace.args.join(" ");
        let folders_joined = self.trace.source_folders.join(" ");
        let mut insert = connection.prepare(
            "INSERT INTO traces (id, program, args, compileCommand, env, workdir, output, sourceFolders, lowLevelFolder, outputFolder, lang, imported, shellID, rrPid, exitCode, calltrace, calltraceMode, date) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )?;
        insert.bind((1, new_id))?;
        insert.bind((2, self.trace.program.as_str()))?;
        insert.bind((3, args_joined.as_str()))?;
        insert.bind((4, self.trace.compile_command.as_str()))?;
        insert.bind((5, self.trace.env.as_str()))?;
        insert.bind((6, self.trace.workdir.as_str()))?;
        insert.bind((7, self.trace.output.as_str()))?;
        insert.bind((8, folders_joined.as_str()))?;
        insert.bind((9, self.trace.low_level_folder.as_str()))?;
        insert.bind((10, self.trace.output_folder.as_str()))?;
        insert.bind((11, self.trace.lang as i64))?;
        insert.bind((12, 1i64))?;
        insert.bind((13, 0i64))?;
        insert.bind((14, -1i64))?;
        insert.bind((15, -1i64))?;
        insert.bind((16, 1i64))?;
        insert.bind((17, "FullRecord"))?;
        insert.bind((18, self.trace.date.as_str()))?;
        let _ = insert.next()?;

        self.trace.id = new_id;
        Ok(())
    }

    fn process_incoming_messages(&mut self) {}

    fn start_core(&mut self) -> Result<(), Box<dyn Error>> {
        let last_start_pid_path = format!("{CODETRACER_TMP_PATH}/last-start-pid");
        let _ = std::fs::create_dir(CODETRACER_TMP_PATH);
        std::fs::write(
            last_start_pid_path,
            format!("{}\n", self.caller_process_pid),
        )?;

        // for now set in shell nix
        // env::set_var("CODETRACER_LINKS_PATH", ..)
        env::set_var("CODETRACER_DISPATCHER_READ_CLIENT", "STDIN");
        env::set_var("CODETRACER_DISPATCHER_SEND_CLIENT", "FILE");

        // https://stackoverflow.com/a/73224567/438099
        // let file = std::fs::File::create("/tmp/codetracer/out.txt").unwrap();
        // let file_out_stdio = Stdio::from(file);

        let caller_pid = self.caller_process_pid;

        let socket_path = format!("{CT_SOCKET_PATH}_{caller_pid}");
        eprintln!("{socket_path:?}");
        let socket = UnixStream::connect(&socket_path)?;
        eprintln!("{socket:?}");

        self.core = Core {
            socket: Some(socket),
            caller_process_pid: self.caller_process_pid,
        };

        Ok(())
    }

    fn setup_events(&mut self) -> Result<(), Box<dyn Error>> {
        Ok(())
    }

    fn send_configure(&self) -> Result<(), Box<dyn Error>> {
        let mut program = vec![self.trace.program.clone()];
        program.extend(self.trace.args.clone());
        let configure_arg = task::ConfigureArg {
            lang: self.trace.lang,
            trace: task::CoreTrace {
                replay: true,
                binary: PathBuf::from(self.trace.program.clone())
                    .file_name()
                    .ok_or(self.trace.program.clone())?
                    .to_str()
                    .unwrap()
                    .to_string(),
                program: program,
                paths: self.trace.source_folders.clone(),
                trace_id: self.trace.id,
                callgraph: false,
                preload_enabled: true,
                call_args_enabled: true,
                trace_enabled: true,
                history_enabled: true,
                events_enabled: true,
                telemetry: false,
                imported: self.trace.imported,
                test: false,
                debug: false,
                trace_output_folder: self.trace.output_folder.clone(),
            },
        };
        self.core.send(TaskKind::Configure, configure_arg)
    }

    async fn run(
        &mut self,
        program_pattern: &str,
        dap_bin: Option<&str>,
    ) -> Result<(), Box<dyn Error>> {
        // might be hardcoded for now or just missing
        // self.load_config();

        self.links_path = PathBuf::from(env::var("CODETRACER_LINKS_PATH")?);
        self.codetracer_exe_dir = self.links_path.join("bin");

        self.caller_process_pid = caller_process_pid();

        if std::path::Path::new(program_pattern).is_dir() {
            self.trace = self.load_trace_from_folder(program_pattern)?;
            // not needed for tui
            // self.register_trace_in_db()?;
        } else {
            self.trace = self.load_trace_from_program(program_pattern)?;
        }

        // problems with start_socket and unix stream
        // for now use files
        // code in commented_out_socket_code.rs
        // self.init_ipc_with_core().await?;

        self.start_core()?;

        self.setup_events()?;

        self.send_configure()?;

        self.core.send(TaskKind::Start, task::EMPTY_ARG)?;
        self.core.send(TaskKind::RunToEntry, task::EMPTY_ARG)?;

        let (tx, mut rx) = mpsc::channel(1);

        self.track_events(tx.clone());

        if let Some(bin) = dap_bin {
            let mut client = DapClient::start(bin)?;
            client.launch(&self.trace.output_folder, &self.trace.program)?;
            let (dap_tx, mut dap_rx) = mpsc::channel(1);
            client.track(dap_tx);
            let tx_clone = tx.clone();
            tokio::spawn(async move {
                while let Some(msg) = dap_rx.recv().await {
                    if tx_clone.send(CtEvent::Dap(msg)).await.is_err() {
                        break;
                    }
                }
            });
        }

        loop {
            if let Some(event) = rx.recv().await {
                match event {
                    CtEvent::Builtin(ev) => {
                        if let Err(e) = self.process_event(ev) {
                            eprintln!("process_event error: {:?}", e);
                        }
                    }
                    CtEvent::Dap(msg) => {
                        if let Err(e) = self.process_dap_message(msg) {
                            eprintln!("dap event error: {:?}", e);
                        }
                    }
                }
            }
        }
    }

    fn on_complete_move(
        &mut self,
        move_state: MoveState,
        event_id: EventId,
    ) -> Result<(), Box<dyn Error>> {
        self.components[EDITOR_COMPONENT].on_complete_move(move_state.clone(), event_id)?;
        if move_state.reset_flow {
            self.core.send(TaskKind::LoadFlow, move_state.location)?;
        }
        Ok(())
    }

    fn on_updated_flow(
        &mut self,
        flow_update: FlowUpdate,
        event_id: EventId,
    ) -> Result<(), Box<dyn Error>> {
        self.components[EDITOR_COMPONENT].on_updated_flow(flow_update, event_id)?;
        Ok(())
    }

    fn track_events(&mut self, tx: mpsc::Sender<CtEvent>) {
        let tx_actions = tx.clone();
        actions::track_keyboard_events(tx_actions);
        core::track_responses(tx);
    }

    fn process_core_event(
        &mut self,
        event_kind: EventKind,
        event_id: EventId,
        raw: &str,
    ) -> Result<(), Box<dyn Error>> {
        match event_kind {
            EventKind::CompleteMove => {
                let move_state: MoveState = serde_json::from_str(raw)?;
                eprintln!("move state: {:?}", move_state);
                self.on_complete_move(move_state, event_id)
            }
            EventKind::UpdatedFlow => {
                let flow_update: FlowUpdate = serde_json::from_str(raw)?;
                eprintln!("flow_update {:?}", flow_update);
                self.on_updated_flow(flow_update, event_id)
            }
            EventKind::NewNotification => {
                eprintln!("notification: {}", raw);
                Ok(())
            }
            _ => {
                unimplemented!();
            }
        }
    }

    fn process_keyboard_event(
        &mut self,
        key_event: crossterm::event::KeyEvent,
    ) -> Result<(), Box<dyn Error>> {
        // https://docs.rs/crossterm/latest/crossterm/event/struct.PushKeyboardEnhancementFlags.html
        // if key_event.kind == KeyEventKind::Release { only supported for kitty protocol

        match key_event.code {
            KeyCode::F(11) | KeyCode::Char('s') => self.step_in(),
            KeyCode::F(10) | KeyCode::Char('n') => self.next(),
            KeyCode::F(12) | KeyCode::Char('o') => self.step_out(),
            KeyCode::F(8) | KeyCode::Char('c') => self.proceed(),
            KeyCode::Esc => self.exit(),
            _ => {
                eprintln!("not implemented {key_event:?}");
                Ok(())
            }
        }
    }

    fn process_event(&mut self, event: Event) -> Result<(), Box<dyn Error>> {
        match event {
            Event::CoreEvent {
                event_kind,
                event_id,
                raw,
            } => self.process_core_event(event_kind, event_id, &raw),
            Event::Keyboard { key_event } => {
                eprintln!("keyboard {key_event:?}");
                self.process_keyboard_event(key_event)
            }
            _ => {
                eprintln!("not supported event: {:?}", event);
                Ok(())
                // unimplemented!()
            }
        }
    }

    fn process_dap_message(&mut self, msg: serde_json::Value) -> Result<(), Box<dyn Error>> {
        if let Some(typ) = msg.get("type").and_then(|v| v.as_str()) {
            match typ {
                "event" => {
                    if let Some(ev) = msg.get("event").and_then(|v| v.as_str()) {
                        match ev {
                            "initialized" => self.initialized(),
                            _ => Ok(()),
                        }
                    } else {
                        Ok(())
                    }
                }
                "response" => {
                    if let Some(cmd) = msg.get("command").and_then(|v| v.as_str()) {
                        match cmd {
                            "launch" => self.launch(),
                            _ => Ok(()),
                        }
                    } else {
                        Ok(())
                    }
                }
                _ => Ok(()),
            }
        } else {
            Ok(())
        }
    }

    fn initialized(&mut self) -> Result<(), Box<dyn Error>> {
        self.status = "initialized".to_string();
        Ok(())
    }

    fn launch(&mut self) -> Result<(), Box<dyn Error>> {
        self.status = "launched".to_string();
        Ok(())
    }

    fn step_in(&mut self) -> Result<(), Box<dyn Error>> {
        self.core.send(TaskKind::Step, StepArg::new(Action::StepIn))
    }

    fn next(&mut self) -> Result<(), Box<dyn Error>> {
        self.core.send(TaskKind::Step, StepArg::new(Action::Next))
    }

    fn step_out(&mut self) -> Result<(), Box<dyn Error>> {
        self.core
            .send(TaskKind::Step, StepArg::new(Action::StepOut))
    }

    fn proceed(&mut self) -> Result<(), Box<dyn Error>> {
        self.core
            .send(TaskKind::Step, StepArg::new(Action::Continue))
    }

    fn exit(&mut self) -> ! {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen);
        std::process::exit(0)
    }

    // read -> message -> method of app
    // eventually calling component/servie method and render
    // e.g. editor_service.on_complete_move(..)
    // self.ensure_editor_component(..)
    // self.components[EDITOR] = self.editor_components[self.editor_service.active_component]
    // self.components[EDITOR].render()

    // same for locals, but start with editor for now

    // parse to a complete move, add Location for now

    // track instrumentation etc

    // can we debug python code?
    // either by logging everything or by special recording
    //   special with gdb but kinda hard whole thing
    // log all we can : each line (maybe again patched cpython?)
    //   render as db
    //   pass by task id
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let args = env::args().collect::<Vec<_>>();
    if args.len() < 2 {
        println!("USAGE: tui <trace-program-pattern>");
        std::process::exit(1);
    }

    let program_pattern = args[1].clone();
    let dap_bin = if args.len() > 2 {
        Some(args[2].clone())
    } else {
        None
    };
    let mut app = App::default();
    app.init_components();

    execute!(io::stdout(), EnterAlternateScreen)?;
    enable_raw_mode()?;

    app.draw_layout()?;

    tokio::spawn(async move {
        let res = app.run(&program_pattern, dap_bin.as_deref()).await;
        eprintln!("run res {:?}", res);
        let _ = app.draw_layout();
    });

    let _ = signal::ctrl_c().await;
    println!("after ctrl-c");

    disable_raw_mode()?;
    execute!(io::stdout(), LeaveAlternateScreen)?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::App;
    use std::path::PathBuf;
    use std::{env, fs};

    #[test]
    fn load_trace_from_folder() {
        let trace_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("trace");
        let app = App::default();
        let trace = app
            .load_trace_from_folder(trace_dir.to_str().unwrap())
            .expect("load trace from folder");
        assert_eq!(trace.program, "example_prog");
        assert_eq!(trace.args, vec!["example_prog".to_string()]);
        assert_eq!(trace.output_folder, trace_dir.to_str().unwrap().to_string());
    }

    #[test]
    fn register_trace_in_db() {
        let base = env::temp_dir().join("ct_tui_test_db");
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();
        let temp_home = base.join("home");
        let db_dir = temp_home.join(".local/share/codetracer");
        fs::create_dir_all(&db_dir).unwrap();
        let db_path = db_dir.join("trace_index.db");
        let connection = sqlite::open(&db_path).unwrap();
        connection
            .execute(
                "CREATE TABLE IF NOT EXISTS traces (
                    id integer,
                    program text,
                    args text,
                    compileCommand text,
                    env text,
                    workdir text,
                    output text,
                    sourceFolders text,
                    lowLevelFolder text,
                    outputFolder text,
                    lang integer,
                    imported integer,
                    shellID integer,
                    rrPid integer,
                    exitCode integer,
                    calltrace integer,
                    calltraceMode string,
                    date text);",
                (),
            )
            .unwrap();
        connection
            .execute(
                "CREATE TABLE IF NOT EXISTS trace_values (id integer, maxTraceID integer, UNIQUE(id));",
                (),
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO trace_values (id, maxTraceID) VALUES (0, 0)",
                (),
            )
            .unwrap();
        drop(connection);

        env::set_var("HOME", temp_home.to_str().unwrap());

        let trace_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("trace");
        let mut app = App::default();
        app.trace = app
            .load_trace_from_folder(trace_dir.to_str().unwrap())
            .unwrap();
        app.register_trace_in_db().unwrap();

        let connection = sqlite::open(&db_path).unwrap();
        let mut st = connection.prepare("SELECT COUNT(*) FROM traces").unwrap();
        let count = if let Ok(sqlite::State::Row) = st.next() {
            st.read::<i64, _>(0).unwrap()
        } else {
            0
        };
        assert_eq!(count, 1);
        assert_eq!(app.trace.id, 1);
    }
}
