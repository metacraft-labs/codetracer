//! A replay worker that exits after it connected fails the query waiting on
//! it at once, with how it ended, instead of leaving the query to its
//! timeout.
//!
//! A worker's socket outlives the worker: `rr` and the program it replays
//! inherit it, so when the worker dies the session's end sees no EOF while
//! they live. The GPUI window's first requests waited on such a `flow` worker
//! until the window's 30 s handshake gave up (codetracer-pm
//! `issues/2026-11-18-replay-server-waits-on-a-flow-worker-that-died-after-connecting.md`).
//!
//! The socket's other end is this test, which accepts the connection and
//! keeps it open without answering: it stands in for the orphaned `rr` tree
//! holding the inherited socket (justified: the defect is in the session's
//! wait, and a real worker cannot be made to die at a chosen point with its
//! socket held open by a survivor). The spawned "worker" is a `/bin/sh` stub
//! that exits with status 7 after a moment. This file holds one test because
//! the query timeout is read from the process environment.

#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use db_backend::paths::recreator_socket_path;
use db_backend::query::ReplayQuery;
use db_backend::recreator_session::ReplayWorker;

/// The query timeout the session is given: far longer than any wait the test
/// accepts, so a query that is failed by its timeout cannot pass.
const QUERY_TIMEOUT_SECS: &str = "60";

/// How long the session may take to notice the worker is gone.
const PROMPTLY: Duration = Duration::from_secs(5);

fn write_short_lived_worker(dir: &Path) -> PathBuf {
    let path = dir.join("short-lived-worker");
    std::fs::write(&path, "#!/bin/sh\nsleep 1\nexit 7\n").expect("write stub worker");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod stub worker");
    path
}

/// Start a worker whose socket is held open, by this test, after the stub
/// exits. Returns the worker, the thread holding the socket, and the socket
/// path (for cleanup).
fn start_worker_with_orphaned_socket(name: &str, temp: &Path) -> (ReplayWorker, thread::JoinHandle<()>, PathBuf) {
    let stub = write_short_lived_worker(temp);
    let trace_folder = temp.join("trace");
    std::fs::create_dir_all(&trace_folder).expect("create trace folder");
    let socket_path = recreator_socket_path("", name, 0, &std::process::id().to_string()).expect("socket path");
    let _ = std::fs::remove_file(&socket_path);
    let listener = UnixListener::bind(&socket_path).expect("bind worker socket");
    let holder = thread::spawn(move || {
        if let Ok((stream, _)) = listener.accept() {
            // Hold the connection open, answering nothing, well past the
            // test's patience; dropped when the test process ends.
            thread::sleep(Duration::from_secs(90));
            drop(stream);
        }
    });
    let mut worker = ReplayWorker::new(name, 0, &stub, &trace_folder);
    worker.start().expect("the session connects to the worker socket");
    (worker, holder, socket_path)
}

fn assert_died_promptly(what: &str, started: Instant, result: Result<String, Box<dyn std::error::Error>>) {
    let waited = started.elapsed();
    let error = match result {
        Ok(answer) => panic!("{what}: the query was answered ({answer:?}) by a worker that had exited"),
        Err(error) => error.to_string(),
    };
    assert!(
        waited < PROMPTLY,
        "{what}: the query failed only after {waited:?}, its timeout, not when the worker exited: {error}"
    );
    assert!(
        error.contains("exit status: 7"),
        "{what}: the error does not say how the worker ended: {error}"
    );
}

#[test]
fn a_worker_that_exits_after_connecting_fails_its_queries_at_once() {
    // SAFETY: this test binary holds this single test, and the variable is
    // set before any thread that reads it exists.
    unsafe { std::env::set_var("CODETRACER_REPLAY_QUERY_TIMEOUT_SECS", QUERY_TIMEOUT_SECS) };
    let temp = tempfile::tempdir().expect("create temp dir");
    let pid = std::process::id();

    // The worker exits while the query waits on it.
    let (mut worker, _holder, socket_path) =
        start_worker_with_orphaned_socket(&format!("exits-mid-query-{pid}"), temp.path());
    let started = Instant::now();
    let result = worker.dispatch_replay_query(ReplayQuery::LoadLocation);
    assert_died_promptly("a worker that exits during a query", started, result);
    assert!(
        worker.last_death().is_some(),
        "the session did not record the worker's death"
    );
    // A later query does not wait on the dead worker either.
    let started = Instant::now();
    let later = worker.dispatch_replay_query(ReplayQuery::LoadLocation);
    assert!(
        later.is_err() && started.elapsed() < PROMPTLY,
        "a query after the death waited {:?} or succeeded: {later:?}",
        started.elapsed()
    );
    drop(worker);
    let _ = std::fs::remove_file(&socket_path);

    // The worker exits between queries: the next query is not sent into a
    // socket nothing will answer.
    let (mut worker, _holder, socket_path) =
        start_worker_with_orphaned_socket(&format!("exits-idle-{pid}"), temp.path());
    thread::sleep(Duration::from_secs(2));
    let started = Instant::now();
    let result = worker.dispatch_replay_query(ReplayQuery::LoadLocation);
    assert_died_promptly("a worker that exited between queries", started, result);
    drop(worker);

    // The run directory is this test process's own (named after its pid): it
    // holds the sockets and the stubs' logs, and nothing else uses it.
    if let Some(run_dir) = socket_path.parent() {
        let _ = std::fs::remove_dir_all(run_dir);
    }
}
