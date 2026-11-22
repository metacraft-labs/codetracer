//! `record-web` starts, records a session and exits cleanly when its main
//! thread has only the 1 MiB of stack Windows gives a process by default.
//!
//! The defect this guards against: on Windows x64 a debug `session-manager
//! record-web` died before it had bound its socket, with `thread 'main' has
//! overflowed its stack` (exit status `0xC00000FD`, `STATUS_STACK_OVERFLOW`).
//! The same binary worked on Linux and macOS only because their main thread
//! gets 8 MiB.  The cause was a 64 KiB read buffer declared on the stack
//! inside an `async fn` in `observability_fetch.rs`: being held across an
//! `.await`, it became part of that future, and of every future that awaited
//! it, up to `main`'s.  A debug build keeps a separate stack slot for every
//! such temporary.  Measured in an x86_64 Linux debug build, `main`'s poll
//! frame was about 680 KiB, and `main`, `Runtime::block_on` and its inner
//! function each held a 133 KiB copy of `main`'s future, so the main thread
//! needed about 1.2 MiB by the time it parsed the command line, whatever the
//! subcommand.  With the buffer on the heap those frames are 45 KiB and
//! 2-3 KiB, and `record-web` runs in 500 KiB.  Nothing in `record-web`
//! itself was at fault, which is why the guard runs the real binary: any
//! subcommand's future can make every other subcommand overflow.
//!
//! No mocks: the test runs the real binary (Cargo's `CARGO_BIN_EXE_*`),
//! connects a real WebSocket client, and reads the `.ct` the host wrote.
//! The 1 MiB limit is applied the way the kernel applies it to any main
//! thread, through `RLIMIT_STACK` set in the child before `exec`, and the
//! test checks in `/proc/<pid>/limits` that the child really runs under it,
//! so a limit that silently failed to apply cannot make the test pass.
//!
//! Linux only: the main thread's stack is sized from `RLIMIT_STACK` at
//! `exec` there, and `/proc` is how the applied limit is verified.  The
//! frame sizes behind the failure come from the shared Rust code, so a
//! regression shows on Linux before it reaches Windows.
#![cfg(target_os = "linux")]

use std::io::{BufRead, BufReader};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;

const SESSION_MANAGER: &str = env!("CARGO_BIN_EXE_session-manager");

/// Windows' default reserve for a process's main thread, and therefore
/// what `session-manager` must fit in on the platform it failed on.
const WINDOWS_MAIN_THREAD_STACK: u64 = 1024 * 1024;

/// How long the host gets to print its "listening on" line.  Generous for
/// a loaded CI host; the line appears within milliseconds normally.
const STARTUP_TIMEOUT: Duration = Duration::from_secs(60);

/// How long the session exchange, and then the exit after `SIGTERM`, each
/// get.  Both take milliseconds normally; the bound turns a hung host into
/// a failure with its log instead of a test run that never ends.
const STEP_TIMEOUT: Duration = Duration::from_secs(60);

/// The host process, killed when the test fails before it has stopped the
/// host itself, so a failed assertion does not leave it running.
struct Host(Child);

impl Drop for Host {
    fn drop(&mut self) {
        // Both are no-ops once `wait` has reaped the child.
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Wait up to `timeout` for `child` to exit; `None` if it is still running.
fn wait_until(child: &mut Child, timeout: Duration) -> Option<std::process::ExitStatus> {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait().expect("poll session-manager") {
            return Some(status);
        }
        if std::time::Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Start `session-manager record-web` with its main thread's stack limited
/// to [`WINDOWS_MAIN_THREAD_STACK`].
fn spawn_constrained(out_dir: &Path, home: &Path) -> Child {
    let mut command = Command::new(SESSION_MANAGER);
    command
        .args(["record-web", "--bind", "127.0.0.1:0", "--out-dir"])
        .arg(out_dir)
        .arg("--workdir")
        .arg(out_dir)
        // The test stops the host itself; the watchdog is not under test.
        .args(["--idle-timeout", "off"])
        // Every per-user path lands in scratch, not the developer's profile.
        .env("CODETRACER_HOME", home)
        .env_remove("CODETRACER_RECORD_WEB_IDLE_TIMEOUT")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    // SAFETY: `pre_exec` runs in the forked child before `exec`; it calls
    // only `getrlimit`/`setrlimit`, which are async-signal-safe, and
    // allocates nothing.
    unsafe {
        command.pre_exec(|| {
            let mut limit = libc::rlimit {
                rlim_cur: 0,
                rlim_max: 0,
            };
            if libc::getrlimit(libc::RLIMIT_STACK, &mut limit) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            // Lower the soft limit only; the hard limit stays as inherited
            // (a soft limit may not exceed it, and 1 MiB never does).
            limit.rlim_cur = WINDOWS_MAIN_THREAD_STACK as libc::rlim_t;
            if libc::setrlimit(libc::RLIMIT_STACK, &limit) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command.spawn().expect("spawn session-manager record-web")
}

/// The soft stack limit `/proc/<pid>/limits` reports for `pid`.
fn soft_stack_limit(pid: u32) -> String {
    let limits = std::fs::read_to_string(format!("/proc/{pid}/limits"))
        .unwrap_or_else(|e| panic!("read /proc/{pid}/limits: {e}"));
    let line = limits
        .lines()
        .find(|l| l.starts_with("Max stack size"))
        .unwrap_or_else(|| panic!("no stack line in /proc/{pid}/limits:\n{limits}"));
    line.split_whitespace()
        .nth(3)
        .unwrap_or_else(|| panic!("malformed stack line: {line}"))
        .to_string()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn record_web_runs_on_a_one_mebibyte_main_thread_stack() {
    let scratch = tempfile::tempdir().expect("scratch dir");
    let out_dir = scratch.path().join("out");
    let home = scratch.path().join("home");
    std::fs::create_dir_all(&home).expect("create CODETRACER_HOME");

    let mut host = Host(spawn_constrained(&out_dir, &home));
    let child = &mut host.0;
    let pid = child.id();

    // Forward every stderr line, so that the listening line can be waited
    // for and the full log is available to explain a failure.
    let stderr = child.stderr.take().expect("piped stderr");
    let (tx, rx) = mpsc::channel::<String>();
    let reader = std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines() {
            let Ok(line) = line else { break };
            if tx.send(line).is_err() {
                break;
            }
        }
    });

    let mut log = Vec::new();
    let mut endpoint = None;
    let deadline = std::time::Instant::now() + STARTUP_TIMEOUT;
    while endpoint.is_none() {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        match rx.recv_timeout(remaining) {
            Ok(line) => {
                if let Some(rest) = line.split("listening on ").nth(1) {
                    endpoint = Some(rest.trim().to_string());
                }
                log.push(line);
            }
            // The sender is gone: the host exited before it was listening.
            Err(_) => {
                let status = child.wait().expect("wait for session-manager");
                panic!(
                    "record-web stopped before listening on a 1 MiB main-thread stack \
                     ({status}); its stderr:\n{}",
                    log.join("\n"),
                );
            }
        }
    }
    let endpoint = endpoint.unwrap();

    // The positive control: the host really is running under the limit.
    assert_eq!(
        soft_stack_limit(pid),
        WINDOWS_MAIN_THREAD_STACK.to_string(),
        "the child must run with a 1 MiB main-thread stack for this test to mean anything",
    );

    // Record one session, so the writer runs too, not only the startup.
    let exchange = async {
        let (mut ws, _response) = tokio_tungstenite::connect_async(&endpoint)
            .await
            .unwrap_or_else(|e| panic!("connect to {endpoint}: {e}"));
        let batch = [
            r#"{"kind":"SessionStart","program":"stack","args":[]}"#,
            r#"{"kind":"Step","siteId":0}"#,
            r#"{"kind":"Value","name":"x","value":{"value":42,"typeKind":"Int"}}"#,
            r#"{"kind":"Step","siteId":1}"#,
            r#"{"kind":"SessionEnd"}"#,
        ]
        .join("\n");
        ws.send(Message::Text(batch)).await.expect("send session");
        ws.close(None).await.ok();
        // The host drops the connection only once it has handled every
        // frame before the close, so reading to the end of the stream means
        // the session has reached the writer before the host is stopped.
        while let Some(Ok(_)) = ws.next().await {}
    };
    if tokio::time::timeout(STEP_TIMEOUT, exchange).await.is_err() {
        log.extend(rx.try_iter());
        panic!(
            "record-web did not finish the session within {STEP_TIMEOUT:?}; its stderr:\n{}",
            log.join("\n"),
        );
    }

    // SIGTERM is one of the documented graceful stops: it flushes in-flight
    // recordings before exiting.
    // SAFETY: `pid` is our own child, not yet reaped, so it cannot have
    // been reused.
    assert_eq!(unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) }, 0);
    let Some(status) = wait_until(child, STEP_TIMEOUT) else {
        log.extend(rx.try_iter());
        panic!(
            "record-web did not exit within {STEP_TIMEOUT:?} of SIGTERM; its stderr:\n{}",
            log.join("\n"),
        );
    };
    reader.join().expect("stderr reader");
    log.extend(rx.try_iter());
    assert!(
        status.success(),
        "record-web must exit cleanly on a 1 MiB main-thread stack ({status}); its stderr:\n{}",
        log.join("\n"),
    );

    let ct = out_dir.join("stack.ct");
    assert!(
        ct.is_file(),
        "expected the recording at {}; stderr:\n{}",
        ct.display(),
        log.join("\n"),
    );
}
