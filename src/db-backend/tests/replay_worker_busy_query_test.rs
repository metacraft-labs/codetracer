//! A query that moves the user's replay is waited for while its worker is
//! slow but still working; every other query keeps the plain read timeout.
//!
//! On a loaded host an rr `RunToEntry` or reverse continue took more than the
//! 10 s read timeout. `dispatch_replay_query` then stopped the worker, and the
//! next query found none: the desktop's value-origin walk failed with "the
//! replay worker is not connected", and a run-to-entry ended where it began.
//! The wait now goes on while the worker's process tree uses CPU
//! (`WorkerProgress` in `recreator_session.rs`); an idle worker still times
//! out (`replay_worker_query_timeout_test.rs`).
//!
//! The wait is only for those queries, on the replay that holds the user's
//! position (`waits_on_a_busy_worker`). Waited on for every query, it left
//! an MCR call trace's flow undrawn for over a minute, where the timeout and
//! a fresh worker had drawn it in seconds. So a read (`LoadLocation`) on the
//! main replay, and a motion on the `flow` side replay, still time out.
//!
//! The worker on the other end is this test itself, listening on the socket
//! path the session computes, so the timing is exact. The spawned "worker"
//! process is a `/bin/sh` stub that spins, using CPU the way a replaying rr
//! does; it stands in for the real `ct-native-replay` (justified: the defect
//! is in the client's wait, which needs a server whose answer can be delayed
//! on demand while its process is busy, and the real worker cannot be made
//! slow on demand). This file holds one test because the query timeout is
//! read from the process environment; its cases run one after another.

#![cfg(target_os = "linux")]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use db_backend::paths::recreator_socket_path;
use db_backend::query::ReplayQuery;
use db_backend::recreator_session::ReplayWorker;

fn write_busy_worker(dir: &Path) -> PathBuf {
    let path = dir.join("busy-worker");
    std::fs::write(&path, "#!/bin/sh\nwhile :; do :; done\n").expect("write stub worker");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod stub worker");
    path
}

/// Start the busy stub as the worker `role`, have the socket's other end
/// answer the first query three seconds late (three read timeouts) and every
/// later one at once, and send `first` then a `LoadLocation`. Returns both
/// answers, or the errors that ended them.
fn two_queries(
    dir: &Path,
    role: &str,
    first: ReplayQuery,
    waits_on_busy_motions: bool,
) -> (Result<String, String>, Result<String, String>) {
    let stub = write_busy_worker(dir);
    let trace_folder = dir.join("trace");
    std::fs::create_dir_all(&trace_folder).expect("create trace folder");

    let socket_path = recreator_socket_path("", role, 0, &std::process::id().to_string()).expect("socket path");
    let _ = std::fs::remove_file(&socket_path);
    let listener = UnixListener::bind(&socket_path).expect("bind worker socket");

    let server = thread::spawn(move || {
        let Ok((stream, _)) = listener.accept() else {
            return;
        };
        let mut writer = stream.try_clone().expect("clone worker stream");
        let mut reader = BufReader::new(stream);
        let mut index = 0;
        let mut line = String::new();
        while reader.read_line(&mut line).map(|n| n > 0).unwrap_or(false) {
            if index == 0 {
                thread::sleep(Duration::from_secs(3));
            }
            let answer = format!("\"answer to query {index}\"\n");
            if writer.write_all(answer.as_bytes()).is_err() {
                return;
            }
            index += 1;
            line.clear();
        }
    });

    let mut worker = ReplayWorker::new(role, 0, &stub, &trace_folder);
    worker.start().expect("the session connects to the worker socket");
    worker.set_waits_on_busy_motions(waits_on_busy_motions);
    let first = worker.dispatch_replay_query(first).map_err(|e| e.to_string());
    let second = worker
        .dispatch_replay_query(ReplayQuery::LoadLocation)
        .map_err(|e| e.to_string());

    drop(worker);
    let _ = server.join();
    if let Some(run_dir) = socket_path.parent() {
        let _ = std::fs::remove_dir_all(run_dir);
    }
    (first, second)
}

#[test]
fn a_motion_of_the_users_replay_is_waited_for_and_nothing_else_is() {
    // SAFETY: this test binary holds this single test, and the variables are
    // set before any thread that reads them exists.
    unsafe {
        std::env::set_var("CODETRACER_REPLAY_QUERY_TIMEOUT_SECS", "1");
        std::env::set_var("CODETRACER_REPLAY_QUERY_MAX_SECS", "30");
    }
    let pid = std::process::id();

    // A run to entry on the main replay: waited for, and the connection is
    // still paired afterwards.
    let temp = tempfile::tempdir().expect("create temp dir");
    let (first, second) = two_queries(
        temp.path(),
        &format!("busy-motion-{pid}"),
        ReplayQuery::RunToEntry,
        false,
    );
    assert_eq!(
        first.as_deref(),
        Ok("\"answer to query 0\""),
        "a motion of the user's replay must be waited for while its worker works"
    );
    assert_eq!(
        second.as_deref(),
        Ok("\"answer to query 1\""),
        "the connection must still be paired after the slow answer"
    );

    // A read on the main replay: the timeout ends it.
    let temp = tempfile::tempdir().expect("create temp dir");
    let (first, _) = two_queries(
        temp.path(),
        &format!("busy-read-{pid}"),
        ReplayQuery::LoadLocation,
        false,
    );
    assert!(
        first.as_ref().is_err_and(|e| e.contains("timed out")),
        "a read must end at the read timeout however busy the worker is, got {first:?}"
    );

    // A motion on the flow side replay: the timeout ends it too.
    let temp = tempfile::tempdir().expect("create temp dir");
    let (first, _) = two_queries(
        temp.path(),
        "flow",
        ReplayQuery::Step {
            action: db_backend::task::Action::Next,
            forward: true,
        },
        false,
    );
    assert!(
        first.as_ref().is_err_and(|e| e.contains("timed out")),
        "a query of the flow replay must end at the read timeout however busy its worker is, got {first:?}"
    );

    // The same motion on the flow replay, when one request waits on it (the
    // flow value popup returning to a step's stop): waited for.
    let temp = tempfile::tempdir().expect("create temp dir");
    let (first, second) = two_queries(
        temp.path(),
        "flow",
        ReplayQuery::Step {
            action: db_backend::task::Action::Next,
            forward: true,
        },
        true,
    );
    assert_eq!(
        first.as_deref(),
        Ok("\"answer to query 0\""),
        "a flow replay's motion that a request waits on must be waited for while its worker works"
    );
    assert_eq!(second.as_deref(), Ok("\"answer to query 1\""));
}
