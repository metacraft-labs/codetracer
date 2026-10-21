//! A `.ct` written by `ct-jsbound assemble` opens in the readers CodeTracer
//! already has, which know nothing of `jsbound.*` (CTFS-Binary-Format.md
//! §4.8, "Unknown-member rule").
//!
//! JBR-M1 verification entry: `e2e_jsbound_ct_opens_in_existing_readers`.
//!
//! No mocks. The container is produced by the real `ct-jsbound` binary,
//! opened by the real `codetracer_ctfs::CtfsReader`, and by the real
//! `ct trace info` path: `session-manager trace info`, which starts the
//! session-manager daemon, which spawns the real `replay-server` to open the
//! trace. Those two binaries come from the sibling crates in this repository
//! (`src/backend-manager`, `src/db-backend`); `just test-rust` builds them
//! and passes their paths in `JSBOUND_E2E_SESSION_MANAGER` and
//! `CODETRACER_REPLAY_SERVER_CMD`. Without them the test FAILS, naming the
//! build commands, unless `JSBOUND_E2E_ALLOW_MISSING=1` is set (a local
//! iteration opt-out that is never set in a CI gate; the skip is then
//! appended to `CODETRACER_TEST_SKIP_REPORT` so the lane reports it).

mod support;

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use codetracer_ctfs::CtfsReader;
use codetracer_trace_writer::meta_dat::decode_meta_dat;
use jsbound::{decode_log, Termination};
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

/// `session-manager trace info <ct>` against a private daemon, then stop the
/// daemon. Returns (exit status, stdout, stderr).
fn trace_info(
    session_manager: &Path,
    replay_server: &Path,
    scratch: &Path,
    ct: &Path,
) -> (i32, String, String) {
    // The client and the daemon both place the socket under
    // `$CODETRACER_HOME/tmp` (backend-manager `paths.rs`), so a scratch
    // CODETRACER_HOME gives this test its own daemon and keeps it out of the
    // developer's profile.
    let run = |args: &[&str]| {
        Command::new(session_manager)
            .args(args)
            .env("TMPDIR", scratch)
            .env("CODETRACER_HOME", scratch.join("home"))
            .env_remove("CODETRACER_DAEMON_SOCKET")
            .env_remove("CODETRACER_TMP_PATH")
            .env("CODETRACER_REPLAY_SERVER_CMD", replay_server)
            .stdin(Stdio::null())
            .output()
            .expect("session-manager runs")
    };
    let started = Instant::now();
    let out = run(&["trace", "info", ct.to_str().unwrap()]);
    let _ = run(&["daemon", "stop"]);
    assert!(
        started.elapsed() < Duration::from_secs(300),
        "ct trace info took {:?}",
        started.elapsed()
    );
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
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
    let Some(session_manager) = locate(
        "JSBOUND_E2E_SESSION_MANAGER",
        &[
            "../../src/backend-manager/target/release/session-manager",
            "../../src/backend-manager/target/debug/session-manager",
        ],
    ) else {
        if missing_prerequisite(
            TEST,
            "the session-manager binary (`ct trace info`) is not built",
        ) {
            return;
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
        if missing_prerequisite(TEST, "the replay-server binary is not built") {
            return;
        }
        unreachable!()
    };
    let (code, stdout, stderr) = trace_info(&session_manager, &replay_server, tmp.path(), &ct);
    println!("ct trace info (exit {code}):\n{stdout}{stderr}");
    assert_eq!(
        code, 0,
        "ct trace info failed\nstdout:\n{stdout}\nstderr:\n{stderr}"
    );
    assert!(stdout.contains("Trace Information"), "stdout:\n{stdout}");
    assert!(
        stdout.contains("Total events:  0"),
        "ct trace info should report no steps\nstdout:\n{stdout}"
    );
}
