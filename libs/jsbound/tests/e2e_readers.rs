//! A `.ct` written by `ct-jsbound assemble` opens in the readers CodeTracer
//! already has, which know nothing of `jsbound.*` (CTFS-Binary-Format.md
//! §4.8, "Unknown-member rule").
//!
//! JBR-M1 verification entry: `e2e_jsbound_ct_opens_in_existing_readers`.
//! `e2e_jsbound_ct_answers_every_query_with_no_steps` then asks the same
//! kind of recording every read-only query of the Python Trace Query API and
//! requires each to answer.
//!
//! No mocks. The container is produced by the real `ct-jsbound` binary,
//! opened by the real `codetracer_ctfs::CtfsReader`, and by the real
//! `ct trace info` path: `session-manager trace info`, which starts the
//! session-manager daemon, which spawns the real `replay-server` to open the
//! trace. The replay-server is then asked, over the daemon's own DAP
//! protocol (the one the Python API and the MCP server speak), whether the
//! recording has any steps: it has no step 0 and stepping reaches the end at
//! once. The `Total events` line of `ct trace info` cannot show that, because
//! the daemon reads it from `meta.dat`.
//!
//! Those two binaries come from the sibling crates in this repository
//! (`src/backend-manager`, `src/db-backend`); `just test-rust` builds them
//! and passes their paths in `JSBOUND_E2E_SESSION_MANAGER` and
//! `CODETRACER_REPLAY_SERVER_CMD`. Without them the test FAILS, naming the
//! build commands, unless `JSBOUND_E2E_ALLOW_MISSING=1` is set (a local
//! iteration opt-out that is never set in a CI gate; the skip is then
//! appended to `CODETRACER_TEST_SKIP_REPORT` so the lane reports it).

mod support;

use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use codetracer_ctfs::CtfsReader;
use codetracer_trace_writer::meta_dat::decode_meta_dat;
use jsbound::{decode_log, Termination};
use serde_json::{json, Value};
use support::*;

const ALLOW_MISSING: &str = "JSBOUND_E2E_ALLOW_MISSING";

/// The binary named by `env_var`, or the first of `candidates` (relative to
/// this crate) that exists.
fn locate(env_var: &str, candidates: &[&str]) -> Option<PathBuf> {
    if let Some(p) = std::env::var_os(env_var).filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(p));
    }
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    candidates
        .iter()
        .map(|c| root.join(c))
        .find(|p| p.is_file())
}

fn missing_prerequisite(test: &str, what: &str) -> bool {
    let msg = format!(
        "{test}: {what}. Build them with `cargo build --release --bin session-manager` in \
         src/backend-manager and `cargo build --release --bin replay-server` in src/db-backend \
         (just test-rust does), or point JSBOUND_E2E_SESSION_MANAGER / CODETRACER_REPLAY_SERVER_CMD at them."
    );
    if std::env::var(ALLOW_MISSING).as_deref() == Ok("1") {
        println!("SKIP (NOT VERIFIED, {ALLOW_MISSING}=1): {msg}");
        if let Some(report) = std::env::var_os("CODETRACER_TEST_SKIP_REPORT") {
            if let Ok(mut f) = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(report)
            {
                let _ = writeln!(f, "{test}: {what}");
            }
        }
        return true;
    }
    panic!("{msg}");
}

/// A private session-manager daemon for this test, reached by the CLI and by
/// the test itself on one socket. Stopped (with the replay-servers it
/// started) on drop.
struct PrivateDaemon {
    session_manager: PathBuf,
    replay_server: PathBuf,
    scratch: PathBuf,
    /// `CODETRACER_DAEMON_SOCKET`: the client verbs and the daemon they
    /// start resolve it alike (backend-manager `DaemonConfig::daemon_paths`).
    socket: PathBuf,
}

impl PrivateDaemon {
    fn new(session_manager: &Path, replay_server: &Path, scratch: &Path) -> PrivateDaemon {
        PrivateDaemon {
            session_manager: session_manager.to_path_buf(),
            replay_server: replay_server.to_path_buf(),
            scratch: scratch.to_path_buf(),
            socket: scratch.join("daemon.sock"),
        }
    }

    /// `session-manager <args>`, which auto-starts the daemon on `socket`.
    /// A scratch CODETRACER_HOME keeps everything else the daemon and the
    /// replay-server write (per-replay sockets, logs) out of the developer's
    /// profile. Returns (exit status, stdout, stderr).
    fn run(&self, args: &[&str]) -> (i32, String, String) {
        let out = Command::new(&self.session_manager)
            .args(args)
            .env("TMPDIR", &self.scratch)
            .env("CODETRACER_HOME", self.scratch.join("home"))
            .env("CODETRACER_DAEMON_SOCKET", &self.socket)
            .env_remove("CODETRACER_TMP_PATH")
            .env("CODETRACER_REPLAY_SERVER_CMD", &self.replay_server)
            .stdin(Stdio::null())
            .output()
            .expect("session-manager runs");
        (
            out.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&out.stdout).into_owned(),
            String::from_utf8_lossy(&out.stderr).into_owned(),
        )
    }

    /// A client connection speaking the daemon's own protocol: DAP framing
    /// (`Content-Length: N\r\n\r\n` + JSON, the Debug Adapter Protocol's
    /// base protocol, https://microsoft.github.io/debug-adapter-protocol/overview#base-protocol),
    /// the one the Python API (`python-api/codetracer/connection.py`) and the
    /// MCP server use.
    #[cfg(unix)]
    fn connect(&self) -> DapClient<std::os::unix::net::UnixStream> {
        let stream = std::os::unix::net::UnixStream::connect(&self.socket)
            .unwrap_or_else(|e| panic!("connect to the daemon at {}: {e}", self.socket.display()));
        stream
            .set_read_timeout(Some(Duration::from_secs(180)))
            .unwrap();
        DapClient {
            stream,
            seq: 0,
            pending: String::new(),
        }
    }

    /// On Windows the daemon listens on 127.0.0.1 and the "socket" is a file
    /// holding the port (backend-manager `paths.rs`).
    #[cfg(windows)]
    fn connect(&self) -> DapClient<std::net::TcpStream> {
        let port = fs::read_to_string(&self.socket).expect("the daemon's port file");
        let stream =
            std::net::TcpStream::connect(("127.0.0.1", port.trim().parse::<u16>().unwrap()))
                .expect("connect to the daemon");
        stream
            .set_read_timeout(Some(Duration::from_secs(180)))
            .unwrap();
        DapClient {
            stream,
            seq: 0,
            pending: String::new(),
        }
    }
}

impl Drop for PrivateDaemon {
    fn drop(&mut self) {
        let _ = self.run(&["daemon", "stop"]);
    }
}

/// The read deadline of a client stream. `UnixStream` and `TcpStream` both
/// have `set_read_timeout`, but no trait names it.
trait ReadDeadline {
    fn set_deadline(&self, deadline: Duration);
}

#[cfg(unix)]
impl ReadDeadline for std::os::unix::net::UnixStream {
    fn set_deadline(&self, deadline: Duration) {
        self.set_read_timeout(Some(deadline)).unwrap();
    }
}

#[cfg(windows)]
impl ReadDeadline for std::net::TcpStream {
    fn set_deadline(&self, deadline: Duration) {
        self.set_read_timeout(Some(deadline)).unwrap();
    }
}

/// A client of the daemon that asks for the session the `ct trace` commands
/// open: every request it sends carries `hostSourceReads: true`, the setting
/// `ct trace info` sends. The daemon keeps one session per trace and
/// setting, and routes a request without the field (recording sources only)
/// to a session of its own (codetracer-pm
/// `spec/Planned-Features/CodeTracer-MCP-Server.md` §2, "A session's identity
/// is the trace path and whether its replay backend may read the recording's
/// listed sources from the host"), so without it these requests would open,
/// and question, a second replay-server rather than the one `ct trace info`
/// started.
struct DapClient<S: Read + Write + ReadDeadline> {
    stream: S,
    seq: i64,
    /// The command of the request awaiting its response, for failure messages.
    pending: String,
}

impl<S: Read + Write + ReadDeadline> DapClient<S> {
    /// [`DapClient::request`], failing the test unless the response arrives
    /// within `deadline`. The read timeout bounds each read, so a reply that
    /// never comes fails there; the elapsed time is checked as well, because
    /// events arriving in between would otherwise restart the clock.
    fn request_within(&mut self, command: &str, arguments: Value, deadline: Duration) -> Value {
        self.stream.set_deadline(deadline);
        let started = Instant::now();
        let reply = self.request(command, arguments);
        self.stream.set_deadline(Duration::from_secs(180));
        assert!(
            started.elapsed() < deadline,
            "{command} answered after {:?}, later than {deadline:?}",
            started.elapsed()
        );
        reply
    }

    /// Send `command` (its `arguments` marked `hostSourceReads: true`, see
    /// [`DapClient`]) and return its response, skipping the events the
    /// daemon forwards in between.
    fn request(&mut self, command: &str, mut arguments: Value) -> Value {
        arguments
            .as_object_mut()
            .expect("request arguments are an object")
            .insert("hostSourceReads".to_string(), Value::Bool(true));
        self.seq += 1;
        self.pending = command.to_string();
        let body = serde_json::to_vec(&json!({
            "type": "request",
            "seq": self.seq,
            "command": command,
            "arguments": arguments,
        }))
        .unwrap();
        self.stream
            .write_all(format!("Content-Length: {}\r\n\r\n", body.len()).as_bytes())
            .unwrap();
        self.stream.write_all(&body).unwrap();
        loop {
            let msg = self.read_message();
            if msg["type"] == "response" && msg["request_seq"] == self.seq {
                return msg;
            }
        }
    }

    fn read_message(&mut self) -> Value {
        let mut header = Vec::new();
        while !header.ends_with(b"\r\n\r\n") {
            let mut byte = [0u8; 1];
            self.stream
                .read_exact(&mut byte)
                .unwrap_or_else(|e| panic!("no reply to {} from the daemon: {e}", self.pending));
            header.push(byte[0]);
        }
        let header = String::from_utf8(header).expect("an ASCII header");
        let len: usize = header
            .lines()
            .find_map(|l| l.strip_prefix("Content-Length:"))
            .unwrap_or_else(|| panic!("no Content-Length in {header:?}"))
            .trim()
            .parse()
            .unwrap();
        let mut body = vec![0u8; len];
        self.stream
            .read_exact(&mut body)
            .expect("a DAP message body");
        serde_json::from_slice(&body).expect("a JSON DAP message")
    }
}

/// A [`PrivateDaemon`] in `scratch`, running the session-manager and
/// replay-server this repository builds. `None` when they are not built and
/// the test may be skipped ([`missing_prerequisite`]); otherwise it fails.
fn private_daemon(test: &str, scratch: &Path) -> Option<PrivateDaemon> {
    let Some(session_manager) = locate(
        "JSBOUND_E2E_SESSION_MANAGER",
        &[
            "../../src/backend-manager/target/release/session-manager",
            "../../src/backend-manager/target/debug/session-manager",
        ],
    ) else {
        if missing_prerequisite(
            test,
            "the session-manager binary (`ct trace info`) is not built",
        ) {
            return None;
        }
        unreachable!()
    };
    let Some(replay_server) = locate(
        "CODETRACER_REPLAY_SERVER_CMD",
        &[
            "../../src/db-backend/target/release/replay-server",
            "../../src/db-backend/target/debug/replay-server",
        ],
    ) else {
        if missing_prerequisite(test, "the replay-server binary is not built") {
            return None;
        }
        unreachable!()
    };
    Some(PrivateDaemon::new(
        &session_manager,
        &replay_server,
        scratch,
    ))
}

#[test]
fn e2e_jsbound_ct_opens_in_existing_readers() {
    const TEST: &str = "e2e_jsbound_ct_opens_in_existing_readers";
    let tmp = tempfile::tempdir().unwrap();
    let staged = stage(&tmp.path().join("staging"), &session_batches());
    let ct = tmp.path().join("session.ct");
    assemble_files(&ct, &staged, &[]);

    // CtfsReader: exactly the four members of §4.8, in block order, and a
    // meta.dat that declares the recording kind.
    let mut reader = CtfsReader::open(&ct).expect("CtfsReader opens the assembled .ct");
    assert_eq!(
        reader.list_files(),
        vec!["meta.dat", "jsbound.log", "jsbound.blb", "jsbound.chk"],
        "the container's members"
    );
    let meta = decode_meta_dat(&reader.read_file("meta.dat").unwrap()).expect("meta.dat decodes");
    assert_eq!(meta.recorder_id, "codetracer-js-boundary/1");
    assert_eq!(meta.recording_id, RECORDING_ID);
    assert_eq!(meta.flags & 1, 0, "flag bit 0 (MCR) is clear");
    let log = decode_log(&reader.read_file("jsbound.log").unwrap()).expect("jsbound.log decodes");
    assert_eq!(log.termination, Termination::Complete);
    assert_eq!(log.records.len(), 15);
    assert!(
        reader.file_size("jsbound.blb").unwrap() > 0
            && reader.file_size("jsbound.chk").unwrap() == 40
    );

    // `ct trace info`: opens it without error and reports no steps.
    let Some(daemon) = private_daemon(TEST, tmp.path()) else {
        return;
    };
    let started = Instant::now();
    let (code, stdout, stderr) = daemon.run(&["trace", "info", ct.to_str().unwrap()]);
    println!("ct trace info (exit {code}):\n{stdout}{stderr}");
    assert!(
        started.elapsed() < Duration::from_secs(300),
        "ct trace info took {:?}",
        started.elapsed()
    );
    assert_eq!(
        code, 0,
        "ct trace info failed\nstdout:\n{stdout}\nstderr:\n{stderr}"
    );
    assert!(stdout.contains("Trace Information"), "stdout:\n{stdout}");
    // `Total events` is meta.dat's count (backend-manager `trace_metadata.rs`),
    // read by the daemon without the replay-server; the steps are asked of
    // the replay-server below.
    assert!(stdout.contains("Total events:  0"), "stdout:\n{stdout}");
    assert!(
        stdout.contains("Program:       https://shop.example/cart"),
        "stdout:\n{stdout}"
    );

    // The replay-server `ct trace info` started holds the recording open and
    // has no steps. Asked over the daemon's own protocol, on the session that
    // `ct trace info` opened (the path is the canonical one it registered,
    // `resolve_cli_trace_path`).
    let trace_path = ct.canonicalize().unwrap();
    let trace_path = trace_path.to_str().unwrap();
    let mut client = daemon.connect();
    let open = client.request("ct/open-trace", json!({ "tracePath": trace_path }));
    assert_eq!(open["success"], true, "ct/open-trace: {open}");
    assert_eq!(
        open["body"]["cached"], true,
        "the session `ct trace info` opened is still loaded: {open}"
    );
    assert_eq!(
        open["body"]["hostSourceReads"], true,
        "the session is the one the `ct trace` commands open: {open}"
    );
    // Step 0 exists in every trace with at least one step: the replay-server
    // looks it up in its step table (db-backend `Db::jump_to`) and refuses
    // an index that is not there.
    let goto = client.request(
        "ct/py-navigate",
        json!({ "tracePath": trace_path, "method": "goto_ticks", "ticks": 0 }),
    );
    assert_eq!(goto["success"], false, "step 0 should not exist: {goto}");
    assert!(
        goto["message"]
            .as_str()
            .is_some_and(|m| m.contains("execution index 0 is not a source step")),
        "the replay-server's step table should have no step 0: {goto}"
    );
    // And there is nowhere to step to.
    let step = client.request(
        "ct/py-navigate",
        json!({ "tracePath": trace_path, "method": "step_over" }),
    );
    assert_eq!(step["success"], true, "step_over: {step}");
    assert_eq!(
        step["body"]["endOfTrace"], true,
        "step_over on a recording with no steps reaches the end: {step}"
    );
}

/// How long one read-only query may take on a recording with no steps. Each
/// answers in milliseconds; the bound only turns a request that is never
/// answered into a failure that names it instead of a hung test.
const QUERY_DEADLINE: Duration = Duration::from_secs(20);

/// Every read-only query of the Python Trace Query API answers on a recording
/// with no steps, and the ones with a natural empty answer give it.
///
/// Regression test for `ct/py-calltrace` never answering on such a recording:
/// the replay-server's `load_local_calltrace` `expect()`ed the call of the
/// current step, panicked on a trace that has none, and its task thread died
/// without a response, so the script waited until its own timeout. A
/// panicked task thread answers nothing afterwards either, which is why the
/// calltrace is asked FIRST: the queries after it prove the replay-server
/// still serves the session.
///
/// Expected answers: the readers open a boundary recording, skipping the
/// members they do not know, and find no steps; a query on it answers rather
/// than hangs. `calltrace()` is an empty list; queries that need a current
/// step (locals, evaluate, flow) answer with a refusal.
///
/// No mocks: the recording comes from the real `ct-jsbound`, the queries go
/// through the real daemon to the real replay-server, first over the daemon's
/// DAP protocol and then through the Python API itself (`ct trace query`).
#[test]
fn e2e_jsbound_ct_answers_every_query_with_no_steps() {
    const TEST: &str = "e2e_jsbound_ct_answers_every_query_with_no_steps";
    let tmp = tempfile::tempdir().unwrap();
    let staged = stage(&tmp.path().join("staging"), &session_batches());
    let ct = tmp.path().join("session.ct");
    assemble_files(&ct, &staged, &[]);
    let Some(daemon) = private_daemon(TEST, tmp.path()) else {
        return;
    };
    // `ct trace info` starts the daemon and opens the session.
    let (code, stdout, stderr) = daemon.run(&["trace", "info", ct.to_str().unwrap()]);
    assert_eq!(
        code, 0,
        "ct trace info failed\nstdout:\n{stdout}\nstderr:\n{stderr}"
    );
    let trace_path = ct.canonicalize().unwrap();
    let tp = trace_path.to_str().unwrap();
    let mut client = daemon.connect();
    let open = client.request("ct/open-trace", json!({ "tracePath": tp }));
    assert_eq!(open["success"], true, "ct/open-trace: {open}");
    // The queries below reach the replay-server `ct trace info` started.
    assert_eq!(open["body"]["cached"], true, "ct/open-trace: {open}");

    let mut ask = |command: &str, arguments: Value| -> Value {
        let reply = client.request_within(command, arguments, QUERY_DEADLINE);
        println!("{command}: {reply}");
        reply
    };
    let succeeds = |reply: &Value, what: &str| {
        assert_eq!(reply["success"], true, "{what}: {reply}");
    };
    let refuses = |reply: &Value, what: &str| {
        assert_eq!(reply["success"], false, "{what}: {reply}");
        assert!(
            reply["message"].as_str().is_some_and(|m| !m.is_empty()),
            "{what} refuses with a reason: {reply}"
        );
    };

    // The call tree is empty, at the start and further in.
    for start in [0, 5] {
        let calltrace = ask(
            "ct/py-calltrace",
            json!({ "tracePath": tp, "start": start, "count": 50, "depth": 10 }),
        );
        succeeds(&calltrace, "calltrace");
        assert_eq!(
            calltrace["body"]["calls"],
            json!([]),
            "calltrace: {calltrace}"
        );
        assert_eq!(
            calltrace["body"]["callLines"],
            json!([]),
            "calltrace: {calltrace}"
        );
        assert_eq!(
            calltrace["body"]["totalCallsCount"], 0,
            "calltrace: {calltrace}"
        );
    }

    let search = ask(
        "ct/py-search-calltrace",
        json!({ "tracePath": tp, "query": "main", "limit": 10 }),
    );
    succeeds(&search, "search_calltrace");
    assert_eq!(
        search["body"]["calls"],
        json!([]),
        "search_calltrace: {search}"
    );

    let stack = ask("ct/py-stack-trace", json!({ "tracePath": tp }));
    succeeds(&stack, "stack_trace");
    assert_eq!(stack["body"]["frames"], json!([]), "stack_trace: {stack}");

    let events = ask(
        "ct/py-events",
        json!({ "tracePath": tp, "start": 0, "count": 50 }),
    );
    succeeds(&events, "events");
    assert_eq!(events["body"]["events"], json!([]), "events: {events}");

    let terminal = ask(
        "ct/py-terminal",
        json!({ "tracePath": tp, "startLine": 0, "endLine": -1 }),
    );
    succeeds(&terminal, "terminal");
    assert_eq!(terminal["body"]["output"], "", "terminal: {terminal}");

    let tracepoints = ask(
        "ct/py-run-tracepoints",
        json!({ "tracePath": tp, "limit": 10 }),
    );
    succeeds(&tracepoints, "run_tracepoints");
    assert_eq!(
        tracepoints["body"]["results"],
        json!([]),
        "run_tracepoints: {tracepoints}"
    );

    // Queries about the current step, of which there is none.
    refuses(
        &ask(
            "ct/py-locals",
            json!({ "tracePath": tp, "depth": 3, "countBudget": 100 }),
        ),
        "locals",
    );
    refuses(
        &ask(
            "ct/py-evaluate",
            json!({ "tracePath": tp, "expression": "x" }),
        ),
        "evaluate",
    );
    refuses(
        &ask(
            "ct/py-flow",
            json!({ "tracePath": tp, "path": "cart.js", "line": 1, "mode": "call" }),
        ),
        "value_trace",
    );
    refuses(
        &ask(
            "ct/py-origin-chain",
            json!({ "tracePath": tp, "variableName": "x", "maxHops": 4, "lazy": false }),
        ),
        "value_origin",
    );

    // The remaining read-only queries answer too. What they answer is not
    // pinned here: today each is refused (no process list or source reader
    // for this kind of trace, no memory diff helper in this environment),
    // and any of those may grow a real answer; never answering is the
    // defect this test exists to catch.
    for (command, arguments) in [
        ("ct/py-processes", json!({ "tracePath": tp })),
        (
            "ct/py-read-source",
            json!({ "tracePath": tp, "path": "cart.js" }),
        ),
        (
            "ct/py-memory-diff",
            json!({ "tracePath": tp, "eventA": 0, "eventB": 1, "maxDiffs": 10 }),
        ),
    ] {
        let reply = ask(command, arguments);
        assert_eq!(reply["type"], "response", "{command}: {reply}");
    }

    // Every navigation answers: forward and backward there is nowhere to go.
    for method in [
        "step_over",
        "step_in",
        "step_out",
        "step_back",
        "reverse_step_in",
        "reverse_step_out",
        "continue_forward",
        "continue_reverse",
    ] {
        let reply = ask(
            "ct/py-navigate",
            json!({ "tracePath": tp, "method": method }),
        );
        assert_eq!(reply["type"], "response", "{method}: {reply}");
    }

    // Through the Python API, as a script sees it: `calltrace()` is `[]`
    // (before the fix: "Script execution timed out after 20 seconds").
    let started = Instant::now();
    let (code, stdout, stderr) = daemon.run(&[
        "trace",
        "query",
        tp,
        "--timeout",
        "20",
        "-c",
        "print('calltrace', trace.calltrace(), flush=True)",
    ]);
    assert_eq!(
        code,
        0,
        "ct trace query failed after {:?}\nstdout:\n{stdout}\nstderr:\n{stderr}",
        started.elapsed()
    );
    assert!(
        stdout.contains("calltrace []"),
        "stdout:\n{stdout}\nstderr:\n{stderr}"
    );
}
