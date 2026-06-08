//! M-REC-11 acceptance test: the replay-worker spawner and worker
//! rendezvous on a UUIDv7-derived socket directory rather than a
//! PID-derived one.
//!
//! What this test asserts:
//!
//! 1. The spawner-side helper [`reserve_run_id_for_recording`] returns
//!    `<recording_id>` (no suffix) for the first reservation of a
//!    given UUID, and `<recording_id>-<seq>` for concurrent
//!    reservations of the *same* recording — matching the
//!    Runtime-Paths-Strategy §4.3 contract.
//!
//! 2. Spawning a child process with
//!    `CODETRACER_RUN_ID=<recording_id>` and reading the env var
//!    inside the child yields exactly that string back, proving
//!    `Command::env` correctly plumbs the run-id to the worker.
//!
//! 3. The spawner-side socket path (via `recreator_socket_path`) and a
//!    fresh worker-side resolution (`resolve_run_id_for_worker`)
//!    produce *byte-identical* per-run directories — this is the
//!    rendezvous-by-computation property that lets the two sides
//!    agree without a handshake.
//!
//! Note: we deliberately use `/bin/sh` as the "worker stub" rather
//! than spawning a real `ct-native-replay` or `ct-mcr replay-worker`
//! binary.  Those binaries are not built by `cargo test` in this
//! crate; the contract under test is the env-var plumbing and the
//! socket-path computation, both of which are crate-local.

use db_backend::paths::reserve_run_id_for_recording;
#[cfg(unix)]
use db_backend::paths::{CODETRACER_RUN_ID_ENV, recreator_socket_path, resolve_run_id_for_worker};
#[cfg(unix)]
use std::process::Command;

/// A pinned UUIDv7 used throughout this test.  Format matches the
/// canonical lowercase hyphenated form (`uuid` crate default).
const RECORDING_ID: &str = "01949fcc-eeee-7e9c-aaaa-111111111111";

/// M-REC-11 §4.3: the first reservation for a recording produces the
/// bare recording id; the second produces `<id>-1`.  This is the
/// process-local rendezvous nonce contract.
#[test]
fn reserve_run_id_returns_bare_uuid_then_seq_suffix() {
    let first = reserve_run_id_for_recording(RECORDING_ID);
    assert_eq!(first, RECORDING_ID);
    let second = reserve_run_id_for_recording(RECORDING_ID);
    assert_eq!(second, format!("{RECORDING_ID}-1"));
}

/// Spawn a `/bin/sh -c 'echo $CODETRACER_RUN_ID'` with the env var set
/// (the same way `McrReplayWorker::start` / `ReplayWorker::start`
/// configure their children) and confirm the child sees the exact
/// run-id we set.  This is the "spawner passes the run-id to the
/// worker" half of the rendezvous contract.
#[cfg(unix)]
#[test]
fn spawner_propagates_run_id_to_worker_env() {
    // Use a UUID that differs from the one in
    // `reserve_run_id_returns_bare_uuid_then_seq_suffix` to keep tests
    // independent — `reserve_run_id_for_recording` keeps a
    // process-local counter that the other test seeds.
    let recording_id = "01949fcc-ffff-7e9c-aaaa-222222222222";
    let run_id = reserve_run_id_for_recording(recording_id);
    assert_eq!(run_id, recording_id, "first reservation must be the bare id");

    let output = Command::new("/bin/sh")
        .arg("-c")
        .arg(format!("printf '%s' \"${CODETRACER_RUN_ID_ENV}\""))
        .env(CODETRACER_RUN_ID_ENV, &run_id)
        .output()
        .expect("spawn /bin/sh stub worker");
    assert!(
        output.status.success(),
        "stub worker exited non-zero: {:?}",
        output.status
    );
    let observed = String::from_utf8(output.stdout).expect("stub worker stdout must be utf-8");
    assert_eq!(
        observed, run_id,
        "child process must see the same run-id the spawner set; the spawner-to-worker env-var contract is the M-REC-11 rendezvous channel"
    );
}

/// End-to-end socket-path rendezvous: the spawner computes
/// `recreator_socket_path` against the reserved run-id, and the worker
/// — by reading `$CODETRACER_RUN_ID` from its own environment —
/// computes a byte-identical path.  Both sides agree without a
/// handshake.
#[cfg(unix)]
#[test]
fn spawner_and_worker_compute_identical_socket_path() {
    // Pin the runtime base directory so the test is hermetic and
    // does not collide with any real CodeTracer session that might
    // be running alongside the test.
    let tempdir = tempfile::tempdir().expect("create temp runtime dir");
    // SAFETY: env_var mutation is unavoidable for testing env-driven
    // resolution.  Cargo runs tests in a single binary serially by
    // default for env-touching tests in our other suites; we accept
    // the same risk here.
    unsafe {
        std::env::set_var("CODETRACER_RUNTIME_DIR", tempdir.path());
    }

    let recording_id = "01949fcc-1111-7e9c-aaaa-333333333333";
    let spawner_run_id = reserve_run_id_for_recording(recording_id);
    let spawner_socket = recreator_socket_path("", "stable", 0, &spawner_run_id).expect("compute spawner socket path");

    // Worker side: it would read $CODETRACER_RUN_ID and call
    // `recreator_socket_path` (or the matching Nim helper) with the
    // same `worker_name` / `index` / `from` triplet.  Simulate by
    // setting the env var and calling the worker-side resolver.
    unsafe {
        std::env::set_var(CODETRACER_RUN_ID_ENV, &spawner_run_id);
    }
    let worker_run_id = resolve_run_id_for_worker();
    let worker_socket = recreator_socket_path("", "stable", 0, &worker_run_id).expect("compute worker socket path");
    unsafe {
        std::env::remove_var(CODETRACER_RUN_ID_ENV);
        std::env::remove_var("CODETRACER_RUNTIME_DIR");
    }

    assert_eq!(
        worker_run_id, spawner_run_id,
        "worker-side run-id resolution must return the value the spawner set"
    );
    assert_eq!(
        spawner_socket, worker_socket,
        "spawner and worker must compute byte-identical socket paths"
    );

    // The directory name must encode the recording id, not a pid.
    // This is the visible M-REC-11 outcome: `ls $CODETRACER_RUNTIME_DIR/`
    // shows run directories named after recordings, not pids.
    let parent = spawner_socket.parent().expect("socket path has a parent dir");
    let dirname = parent
        .file_name()
        .and_then(|n| n.to_str())
        .expect("parent dir name is utf-8");
    assert_eq!(
        dirname,
        format!("run-{recording_id}"),
        "per-run directory must be named after the recording_id (run-<UUIDv7>), not a PID"
    );
}
