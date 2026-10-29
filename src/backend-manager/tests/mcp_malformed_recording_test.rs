//! A recording whose `meta.dat` declares an impossible count is refused by
//! name, and the session manager every client shares keeps answering every
//! other session.
//!
//! The count is recording content.  A `meta.dat` whose argument count is
//! 2^60 used to reach `Vec::with_capacity` in the session manager; the
//! allocation panicked ("capacity overflow") inside the daemon's dispatch
//! task, the task ended, and from then on the daemon answered no client on
//! any recording.  Here, through the real `trace mcp` and daemon:
//!
//! * `trace_info` and `exec_script` on the malformed recording each answer
//!   with an error naming the count (not a timeout, and not the daemon's
//!   panic message);
//! * then, on the same daemon, a well-formed recording is answered by
//!   `trace_info` and `exec_script` from the same server and from a second
//!   server process, each well within the time a request normally takes.
//!
//! The malformed container is built here, with the writer this crate's unit
//! tests use (`meta_dat::write_minimal_ctfs`) and a `meta.dat` written byte
//! by byte, because the recorders refuse to write one.
//!
//! What is real: the MCP servers, the daemon, the `replay-server`, the
//! Python API; the well-formed recording is written by the production CTFS
//! writer.  No component is mocked.

#![cfg(unix)]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic, dead_code)]

#[path = "support/mcp_harness.rs"]
mod mcp_harness;

#[path = "../src/meta_dat.rs"]
mod meta_dat;

use std::time::{Duration, Instant};

use mcp_harness::*;
use serde_json::json;

const RECORDING_ID: &str = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb";
/// The declared argument count: 2^60, far past what any input holds.
const COUNT: u64 = 1 << 60;
/// A request that takes longer than this is not "answered in the normal
/// time": a well-formed recording's `trace_info` takes well under a second
/// here, and the daemon's own request timeout is 20 s.
const PROMPT: Duration = Duration::from_secs(15);

fn varint(mut value: u64, out: &mut Vec<u8>) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

fn string(text: &str, out: &mut Vec<u8>) {
    varint(text.len() as u64, out);
    out.extend_from_slice(text.as_bytes());
}

/// A version 7 `meta.dat` with no optional block and `count` arguments
/// declared, none present.
fn malformed_meta_dat(count: u64) -> Vec<u8> {
    let mut out = b"CTMD".to_vec();
    out.extend_from_slice(&7u16.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    string(RECORDING_ID, &mut out);
    string("app.py", &mut out);
    varint(count, &mut out);
    string("/w", &mut out);
    string("test", &mut out);
    out
}

async fn timed<T>(what: &str, f: impl std::future::Future<Output = T>) -> T {
    let started = Instant::now();
    let out = f.await;
    let took = started.elapsed();
    assert!(took < PROMPT, "{what} took {took:?}");
    out
}

#[tokio::test(flavor = "multi_thread")]
async fn a_malformed_meta_dat_is_refused_and_other_sessions_are_answered() {
    let (_guard, root) = short_root("ct-malformed-");
    let server = server_binary();
    let replay = replay_server_for(&server);

    let malformed = root.join("malformed");
    std::fs::create_dir_all(&malformed).unwrap();
    meta_dat::write_minimal_ctfs(
        &malformed.join("trace.ct"),
        &[("meta.dat", &malformed_meta_dat(COUNT))],
    )
    .unwrap();
    // Control: the same container with an honest count of zero reads past
    // `meta.dat` (it is refused later, for its missing tables, not its count).
    let honest = root.join("honest");
    std::fs::create_dir_all(&honest).unwrap();
    meta_dat::write_minimal_ctfs(
        &honest.join("trace.ct"),
        &[("meta.dat", &malformed_meta_dat(0))],
    )
    .unwrap();

    let workdir = root.join("work");
    std::fs::create_dir_all(&workdir).unwrap();
    let source = workdir.join("app.py");
    std::fs::write(&source, "def main():\n    total = 0\n    for i in range(3):\n        total += i\n    return total\n").unwrap();
    let good = root.join("good");
    std::fs::create_dir_all(&good).unwrap();
    write_recording(&good, &workdir, &source, &[]);

    let (mut daemon, socket) = start_daemon(&server, &root, &replay).await;
    let mut first = start_mcp(&server, &root, &socket, &with_script_opt_in(&server, &[])).await;

    // The well-formed recording is answered before, so "answered after" is
    // a comparison with the same daemon's normal behaviour.
    timed(
        "trace_info on the good recording, before",
        first.call_tool("trace_info", json!({"trace_path": good})),
    )
    .await
    .expect("the good recording is answered before the malformed one is opened");

    let refusal = timed(
        "trace_info on the malformed recording",
        first.call_tool("trace_info", json!({"trace_path": malformed})),
    )
    .await
    .expect_err("the malformed recording must be refused");
    assert!(
        refusal.contains(&format!("args_count is {COUNT}")),
        "the refusal must name the count: {refusal}"
    );
    assert!(!refusal.contains("panicked"), "{refusal}");
    let honest_refusal = timed(
        "trace_info on the honest container",
        first.call_tool("trace_info", json!({"trace_path": honest})),
    )
    .await
    .expect_err("the honest container has no tables");
    assert!(!honest_refusal.contains("args_count"), "{honest_refusal}");

    let script_refusal = timed(
        "exec_script on the malformed recording",
        first.call_tool(
            "exec_script",
            json!({"trace_path": malformed, "script": "print(1)", "timeout_seconds": 60}),
        ),
    )
    .await
    .expect_err("exec_script on the malformed recording must fail");
    assert!(
        !script_refusal.contains("timed out") && !script_refusal.contains("panicked"),
        "{script_refusal}"
    );

    // Every other session is answered: the same server and a new one.
    let mut second = start_mcp(&server, &root, &socket, &with_script_opt_in(&server, &[])).await;
    for (name, mcp) in [
        ("the same server", &mut first),
        ("a second server", &mut second),
    ] {
        timed(
            &format!("trace_info on the good recording from {name}"),
            mcp.call_tool("trace_info", json!({"trace_path": good})),
        )
        .await
        .unwrap_or_else(|e| panic!("{name}: trace_info on the good recording: {e}"));
        let out = timed(
            &format!("exec_script on the good recording from {name}"),
            mcp.call_tool(
                "exec_script",
                json!({"trace_path": good, "script": "print(len(trace.source_files))", "timeout_seconds": 60}),
            ),
        )
        .await
        .unwrap_or_else(|e| panic!("{name}: exec_script on the good recording: {e}"));
        assert_eq!(out.trim(), "1", "{name}");
    }
    assert!(daemon.try_wait().unwrap().is_none(), "the daemon exited");
    first.stop().await;
    second.stop().await;
    shutdown_daemon(&socket, &mut daemon).await;
}
