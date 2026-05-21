//! Verify that the test-harness DAP read path surfaces a clear diagnostic
//! instead of hanging when no data arrives on the socket.
//!
//! Regression test for task #311: prior to the per-read timeout on the
//! `BufReader<UnixStream>`, a stalled DAP read (caused by a crashed
//! replay-worker or an exhausted free-tier quota) would block the test
//! process indefinitely until nextest SIGTERMed it 350 s later, hiding all
//! stderr context.
//!
//! This test simulates the failure by accepting a Unix-socket connection and
//! deliberately never sending any DAP message, then asserting that
//! `read_dap_message_from_reader` returns a timeout error within the
//! configured budget.  We intentionally do not depend on the full
//! `DapTestClient` harness (which spawns `replay-server`) — exercising the
//! exact mechanism (`set_read_timeout` on a `UnixStream` wrapped in a
//! `BufReader`) is sufficient to lock in the contract.

#![cfg(unix)]

use db_backend::dap;
use std::io::BufReader;
use std::os::unix::net::{UnixListener, UnixStream};
use std::time::{Duration, Instant};

/// A stalled DAP read must return an error mentioning a timeout within roughly
/// the configured budget, not hang indefinitely.
#[test]
fn read_dap_message_with_set_read_timeout_surfaces_diagnostic() {
    // Use a per-process temp socket path so concurrent test runs don't collide.
    let socket_path = std::env::temp_dir().join(format!("ct_dap_read_timeout_test_{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&socket_path);

    let listener = UnixListener::bind(&socket_path).expect("bind unix listener");

    // Connect from the same process so we don't need a child binary.
    let _client = UnixStream::connect(&socket_path).expect("client connect");
    let (server_side, _) = listener.accept().expect("accept");

    // 500ms is short enough to keep the test fast yet far above scheduling
    // noise on a healthy CI runner.
    let budget = Duration::from_millis(500);
    server_side
        .set_read_timeout(Some(budget))
        .expect("set_read_timeout on UnixStream");

    let mut reader = BufReader::new(server_side);

    let start = Instant::now();
    let result = dap::read_dap_message_from_reader(&mut reader);
    let elapsed = start.elapsed();

    // Clean up the socket file regardless of test outcome.
    let _ = std::fs::remove_file(&socket_path);

    let err = result.expect_err("read should fail with a timeout error, not block");
    let msg = err.to_string().to_ascii_lowercase();

    // The exact error spelling varies by OS:
    //   * Linux + glibc: WouldBlock / EAGAIN
    //     -> "Resource temporarily unavailable (os error 11)".
    //   * macOS / *BSD: WouldBlock / EAGAIN
    //     -> "Resource temporarily unavailable (os error 35)".
    //   * Some platforms / explicit non-blocking modes: TimedOut
    //     -> "Operation timed out".
    // Our diagnostic helper (`explain_dap_read_error` in test_harness/mod.rs)
    // matches the same set of substrings — keep these two lists in sync.
    assert!(
        msg.contains("timed out")
            || msg.contains("timedout")
            || msg.contains("would block")
            || msg.contains("resource temporarily unavailable")
            || msg.contains("os error 11")
            || msg.contains("os error 35")
            || msg.contains("os error 60"),
        "expected timeout/would-block/EAGAIN error, got: {}",
        err
    );

    // Bound the elapsed time so a regression (e.g. accidentally clearing the
    // read timeout) would fail loudly rather than slowly.  Allow generous
    // slack for slow CI runners.
    assert!(
        elapsed < budget * 8,
        "expected read to fail within ~{:?}, but took {:?}",
        budget,
        elapsed
    );
}
