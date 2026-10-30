//! `exec_script` runs a script confined unless the server was started with
//! `--allow-unconfined-scripts`: the script changes nothing outside the
//! scratch directory made for its run, whatever sandbox the server runs in.
//!
//! The test runs everything on the host, in no sandbox at all, so nothing
//! but the confinement stands between the script and the host's files.  One
//! script attempts every way of changing something outside its scratch
//! directory that the confinement is meant to close:
//!
//! * the file system: create, truncate, remove, rename, make a directory or
//!   a symlink in a directory outside the scratch directory, and hard-link a
//!   file from there into the scratch directory (a write through the link
//!   would change the outside file);
//! * a child process doing the same write (confinement is inherited);
//! * a Unix socket (the daemon's own, by its path) and a TCP connection to a
//!   listener the test runs on loopback: a service on the host could act for
//!   the script;
//! * the daemon, through the connection the script inherits: `ct/start-replay`
//!   naming a program that writes a file, a nested `ct/exec-script` asking to
//!   be unconfined, `ct/open-trace` of another recording, and
//!   `ct/daemon-shutdown`;
//! * the daemon's environment, which carries a secret the script must not see.
//!
//! Without the option every attempt is refused and the host is unchanged,
//! while the script still queries its trace and writes its scratch directory
//! (removed after the call).
//!
//! VACUITY GUARD.  The same script through a server started with
//! `--allow-unconfined-scripts`, on the same daemon: each write, the child's
//! write, both connections and both daemon requests that run a program take
//! effect.  So every refusal above is the confinement's, not an attempt that
//! could never have worked.
//!
//! ## What is real
//!
//! The MCP servers (`trace mcp`), the daemon, the `replay-server`, the Python
//! API and the kernel's Landlock and seccomp are the production code and the
//! real kernel.  The recordings are written by the production CTFS writer.
//! No component is mocked.  A host where confinement is unavailable fails
//! the test (the confined call is refused there); it is never a skip.

#![cfg(target_os = "linux")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

#[path = "support/mcp_harness.rs"]
mod mcp_harness;

use std::ffi::OsStr;
use std::path::Path;

use mcp_harness::*;
use serde_json::{Value, json};

/// A value only the daemon's environment holds.
const SECRET: &str = "CT_TEST_DAEMON_SECRET";
const SECRET_VALUE: &str = "daemon-secret-4c1e";

/// The attempts that must be refused when confined and must take effect
/// when unconfined.
const WRITES: [&str; 6] = [
    "write_outside",
    "truncate_outside",
    "rename_outside",
    "mkdir_outside",
    "symlink_outside",
    "child_process_write",
];

/// The probe: every attempt in a `try`, its outcome recorded by name, the
/// record printed as the last line.
fn probe_script(
    outside: &Path,
    socket: &Path,
    port: u16,
    other_trace: &Path,
    shutdown: bool,
) -> String {
    format!(
        r#"import json, os, socket, subprocess, sys
OUT = {outside:?}
R = {{}}
def attempt(name, fn):
    try:
        fn()
        R[name] = "done"
    except Exception as e:
        R[name] = "refused: %s: %s" % (type(e).__name__, e)
def write_outside():
    with open(os.path.join(OUT, "written.txt"), "w") as f:
        f.write("x")
attempt("write_outside", write_outside)
attempt("truncate_outside", lambda: os.truncate(os.path.join(OUT, "keep.txt"), 0))
attempt("rename_outside", lambda: os.rename(os.path.join(OUT, "keep.txt"), os.path.join(OUT, "moved.txt")))
attempt("mkdir_outside", lambda: os.mkdir(os.path.join(OUT, "made")))
attempt("symlink_outside", lambda: os.symlink("/etc/hostname", os.path.join(OUT, "link")))
def hardlink():
    # Into the scratch directory when confined (its TMPDIR); unconfined, into
    # the test's own TMPDIR.  A hard link cannot cross file systems, so a
    # TMPDIR elsewhere links into the directory beside OUT instead.
    here = os.environ.get("TMPDIR", ".")
    same = os.stat(here).st_dev == os.stat(OUT).st_dev
    target = os.path.join(here if same else OUT + "-links", "hardlink")
    os.link(os.path.join(OUT, "keep2.txt"), target)
    with open(target, "a") as f:
        f.write(" changed through the link")
attempt("hardlink_into_scratch", hardlink)
def child_write():
    code = "open(%r, 'w').write('x')" % os.path.join(OUT, "child.txt")
    subprocess.run([sys.executable, "-I", "-c", code], check=True, capture_output=True)
attempt("child_process_write", child_write)
def unix_socket():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect({socket:?})
    s.close()
attempt("unix_socket", unix_socket)
def tcp():
    s = socket.create_connection(("127.0.0.1", {port}), timeout=5)
    s.close()
attempt("tcp_connect", tcp)
def daemon(name, command, arguments):
    try:
        resp = trace._connection.send_request(command, arguments)
        R[name] = "done" if resp.get("success") else "refused: " + str(resp.get("message"))
    except Exception as e:
        R[name] = "refused: %s: %s" % (type(e).__name__, e)
started = "open(%r, 'w').write('x')" % os.path.join(OUT, "started.txt")
daemon("daemon_start_replay", "ct/start-replay", [sys.executable, "-I", "-c", started])
nested = "open(%r, 'w').write('x')" % os.path.join(OUT, "nested.txt")
daemon("daemon_nested_exec", "ct/exec-script",
       {{"tracePath": os.environ["CODETRACER_TRACE_PATH"], "script": nested, "unconfinedScripts": True}})
daemon("daemon_other_trace", "ct/open-trace", {{"tracePath": {other_trace:?}}})
def swap():
    # A symlink the script repoints between its own trace and the other one
    # while it opens the link: the grant checks the name, so the open must
    # still reach the script's own trace every time.
    import threading
    own, other = os.environ["CODETRACER_TRACE_PATH"], {other_trace:?}
    link = os.path.join(os.environ.get("TMPDIR", "."), "swap-link")
    os.symlink(own, link)
    stop = []
    def flip():
        i = 0
        while not stop:
            tmp = "%s.%d" % (link, i)
            os.symlink(other if i % 2 else own, tmp)
            os.rename(tmp, link)
            i += 1
    flipper = threading.Thread(target=flip)
    flipper.start()
    seen = {{"own": 0, "other": 0, "refused": 0}}
    try:
        for _ in range(400):
            r = trace._connection.send_request("ct/open-trace", {{"tracePath": link}})
            if not r.get("success"):
                seen["refused"] += 1
            else:
                which = "other" if "other.py" in json.dumps(r.get("body", {{}}).get("sourceFiles")) else "own"
                seen[which] += 1
                # Closed again, so the next open resolves the link afresh
                # rather than finding the session this one left.
                trace._connection.send_request("ct/close-trace", {{"tracePath": link}})
    finally:
        stop.append(True)
        flipper.join()
    R["symlink_swap"] = seen
try:
    swap()
except Exception as e:
    R["symlink_swap"] = "failed: %s: %s" % (type(e).__name__, e)
if {shutdown}:
    daemon("daemon_shutdown", "ct/daemon-shutdown", {{}})
def scratch():
    # Confined, TMPDIR is the scratch directory; unconfined, the test's root.
    with open(os.path.join(os.environ.get("TMPDIR", "."), "scratch.txt"), "w") as f:
        f.write("ok")
attempt("write_scratch", scratch)
R["cwd"] = os.getcwd()
R["secret"] = os.environ.get({SECRET:?})
R["source_files"] = len(trace.source_files)
print(json.dumps(R))
"#,
        shutdown = if shutdown { "True" } else { "False" },
    )
}

fn refused(record: &Value, name: &str) -> bool {
    record[name]
        .as_str()
        .is_some_and(|outcome| outcome.starts_with("refused"))
}

fn done(record: &Value, name: &str) -> bool {
    record[name].as_str() == Some("done")
}

/// The outside directory, fresh: two files the script may not change.
fn reset_outside(outside: &Path) {
    let _ = std::fs::remove_dir_all(outside);
    std::fs::create_dir_all(outside).unwrap();
    let links = outside.with_file_name("outside-links");
    let _ = std::fs::remove_dir_all(&links);
    std::fs::create_dir_all(links).unwrap();
    std::fs::write(outside.join("keep.txt"), "kept").unwrap();
    std::fs::write(outside.join("keep2.txt"), "kept too").unwrap();
}

async fn run_probe(mcp: &mut Mcp, trace_dir: &Path, script: &str) -> Value {
    let out = mcp
        .call_tool(
            "exec_script",
            json!({"trace_path": trace_dir, "script": script, "timeout_seconds": 60}),
        )
        .await
        .unwrap_or_else(|e| panic!("exec_script failed: {e}"));
    let last = out.lines().last().unwrap_or_default();
    serde_json::from_str(last).unwrap_or_else(|e| panic!("no record in {out:?}: {e}"))
}

#[tokio::test(flavor = "multi_thread")]
async fn t_mcp_exec_script_cannot_write_outside_its_scratch() {
    let (_guard, root) = short_root("ct-confine-");
    let server = server_binary();
    let replay = replay_server_for(&server);

    // Two recordings: the one the script runs on and another one.
    let workdir = root.join("work");
    std::fs::create_dir_all(&workdir).unwrap();
    let source = workdir.join("app.py");
    std::fs::write(&source, "def main():\n    total = 0\n    for i in range(3):\n        total += i\n    return total\n").unwrap();
    let trace_dir = root.join("rec");
    std::fs::create_dir_all(&trace_dir).unwrap();
    write_recording(&trace_dir, &workdir, &source, &[]);
    // The other recording names a source of its own, so an answer says
    // which recording it came from.
    let other_source = workdir.join("other.py");
    std::fs::write(&other_source, "def main():\n    return 1\n").unwrap();
    let other_trace = root.join("other");
    std::fs::create_dir_all(&other_trace).unwrap();
    write_recording(&other_trace, &workdir, &other_source, &[]);

    let outside = root.join("outside");
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let port = listener.local_addr().unwrap().port();

    let (mut daemon, socket) = start_daemon_with_env(
        &server,
        &root,
        &replay,
        &[(SECRET, OsStr::new(SECRET_VALUE))],
    )
    .await;

    // --- Confined (the default) ---
    reset_outside(&outside);
    let mut confined = start_mcp(&server, &root, &socket, &[]).await;
    let script = probe_script(&outside, &socket, port, &other_trace, true);
    let record = run_probe(&mut confined, &trace_dir, &script).await;
    eprintln!("confined: {record}");

    let mut failures = Vec::new();
    for name in WRITES
        .iter()
        .chain(&["hardlink_into_scratch", "unix_socket", "tcp_connect"])
        .chain(&[
            "daemon_start_replay",
            "daemon_nested_exec",
            "daemon_other_trace",
            "daemon_shutdown",
        ])
    {
        if !refused(&record, name) {
            failures.push(format!("{name} was not refused: {}", record[*name]));
        }
    }
    // The host is unchanged: exactly the two files, as written.
    let mut left: Vec<String> = std::fs::read_dir(&outside)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    if left != ["keep.txt", "keep2.txt"] {
        failures.push(format!("the outside directory changed: {left:?}"));
    }
    if std::fs::read_to_string(outside.join("keep.txt"))
        .ok()
        .as_deref()
        != Some("kept")
    {
        failures.push("keep.txt changed".into());
    }
    if std::fs::read_to_string(outside.join("keep2.txt"))
        .ok()
        .as_deref()
        != Some("kept too")
    {
        failures.push("keep2.txt changed (through a hard link)".into());
    }
    if listener.accept().is_ok() {
        failures.push("the loopback listener was connected to".into());
    }
    // It ran and could do its work: it queried the trace and wrote its own
    // scratch directory, which no longer exists.
    if !done(&record, "write_scratch") {
        failures.push(format!(
            "the scratch write failed: {}",
            record["write_scratch"]
        ));
    }
    if record["source_files"].as_u64().unwrap_or(0) == 0 {
        failures.push("the script's trace answered no source files".into());
    }
    let cwd = record["cwd"].as_str().unwrap_or_default();
    if !cwd.contains("script-scratch") || Path::new(cwd).exists() {
        failures.push(format!(
            "the scratch directory {cwd:?} is not a removed run directory"
        ));
    }
    if record["secret"] != Value::Null {
        failures.push(format!(
            "the script saw the daemon's environment: {}",
            record["secret"]
        ));
    }
    // The swapped symlink never reached the other recording, and the
    // script's own trace was opened through it.
    let swap = &record["symlink_swap"];
    if swap["other"] != json!(0) || swap["own"].as_u64().unwrap_or(0) == 0 {
        failures.push(format!(
            "the symlink swap reached another recording: {swap}"
        ));
    }
    // The refused shutdown left the daemon serving.
    if daemon.try_wait().unwrap().is_some() {
        failures.push("the daemon exited".into());
    }
    confined.stop().await;

    // --- Vacuity guard: the same script, unconfined ---
    reset_outside(&outside);
    let mut unconfined = start_mcp(&server, &root, &socket, &["--allow-unconfined-scripts"]).await;
    let script = probe_script(&outside, &socket, port, &other_trace, false);
    let record = run_probe(&mut unconfined, &trace_dir, &script).await;
    eprintln!("unconfined: {record}");
    for name in WRITES.iter().chain(&[
        "hardlink_into_scratch",
        "unix_socket",
        "tcp_connect",
        "daemon_nested_exec",
        "daemon_other_trace",
    ]) {
        if !done(&record, name) {
            failures.push(format!(
                "vacuity guard: {name} did not take effect unconfined: {}",
                record[*name]
            ));
        }
    }
    for file in ["written.txt", "child.txt", "nested.txt", "started.txt"] {
        if !outside.join(file).exists() {
            failures.push(format!("vacuity guard: {file} was not written unconfined"));
        }
    }
    if listener.accept().is_err() {
        failures.push("vacuity guard: the loopback listener saw no connection unconfined".into());
    }
    if std::fs::read_to_string(outside.join("keep2.txt"))
        .ok()
        .as_deref()
        != Some("kept too changed through the link")
    {
        failures.push("vacuity guard: keep2.txt was not changed through the hard link".into());
    }
    if record["secret"].as_str() != Some(SECRET_VALUE) {
        failures.push(
            "vacuity guard: the unconfined script did not see the daemon's environment".into(),
        );
    }
    if record["symlink_swap"]["other"].as_u64().unwrap_or(0) == 0 {
        failures.push(format!(
            "vacuity guard: the symlink swap never reached the other recording unconfined: {}",
            record["symlink_swap"]
        ));
    }
    unconfined.stop().await;
    shutdown_daemon(&socket, &mut daemon).await;

    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// A recording to run scripts on, in `root/rec`.
fn simple_recording(root: &Path) -> std::path::PathBuf {
    let workdir = root.join("work");
    std::fs::create_dir_all(&workdir).unwrap();
    let source = workdir.join("app.py");
    std::fs::write(&source, "def main():\n    return 0\n").unwrap();
    let trace_dir = root.join("rec");
    std::fs::create_dir_all(&trace_dir).unwrap();
    write_recording(&trace_dir, &workdir, &source, &[]);
    trace_dir
}

/// One DAP request on `stream` and whether an answer to it arrives within
/// `wait` (an answer of any kind counts).
fn answered(
    stream: &mut std::os::unix::net::UnixStream,
    seq: i64,
    trace: &Path,
    wait: std::time::Duration,
) -> bool {
    use std::io::{Read, Write};
    let body = json!({"type": "request", "command": "ct/py-locals", "seq": seq,
                      "arguments": {"tracePath": trace}})
    .to_string();
    stream
        .write_all(format!("Content-Length: {}\r\n\r\n{body}", body.len()).as_bytes())
        .unwrap();
    stream.set_read_timeout(Some(wait)).unwrap();
    let deadline = std::time::Instant::now() + wait;
    let mut bytes = Vec::new();
    while std::time::Instant::now() < deadline {
        if dap_messages(&bytes)
            .iter()
            .any(|m| m["type"] == "response" && m["request_seq"] == seq)
        {
            return true;
        }
        let mut chunk = [0u8; 8192];
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => return false,
            Ok(n) => bytes.extend_from_slice(&chunk[..n]),
        }
    }
    false
}

/// The connection a confined script inherits is the script's for the call
/// only: a process that still holds it after the call ends is answered
/// nothing.  The leftover holder is this test, which takes a duplicate of
/// the script's descriptor 3 while the script runs (`pidfd_getfd(2)`: the
/// script is a descendant of the test, through the daemon it started), as a
/// process the script left behind would hold it.  While the call runs the
/// duplicate is answered (vacuity guard); after the call it is not.
#[tokio::test(flavor = "multi_thread")]
async fn t_mcp_exec_script_grant_ends_with_the_call() {
    let (_guard, root) = short_root("ct-grant-");
    let server = server_binary();
    let replay = replay_server_for(&server);
    let trace_dir = simple_recording(&root);
    let (mut daemon, socket) = start_daemon(&server, &root, &replay).await;
    let mut mcp = start_mcp(&server, &root, &socket, &[]).await;

    // The script's command line carries this marker, so the test can find it.
    let marker = "GRANT_HOLDER_PROBE_5e2b";
    let script = format!("import time\ntime.sleep(6)  # {marker}\nprint('done')\n");
    let trace_arg = trace_dir.clone();
    let call = tokio::spawn(async move {
        let answer = mcp
            .call_tool(
                "exec_script",
                json!({"trace_path": trace_arg, "script": script, "timeout_seconds": 60}),
            )
            .await;
        mcp.stop().await;
        answer
    });

    // Find the script's process and take its descriptor 3.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    let pid = loop {
        let found = std::fs::read_dir("/proc").unwrap().flatten().find_map(|e| {
            let pid: i32 = e.file_name().to_str()?.parse().ok()?;
            let cmdline = std::fs::read(e.path().join("cmdline")).ok()?;
            String::from_utf8_lossy(&cmdline)
                .contains(marker)
                .then_some(pid)
        });
        if let Some(pid) = found {
            break pid;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the script never started"
        );
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    };
    // SAFETY: plain system calls on a pid and the descriptors they return.
    let held = unsafe {
        let pidfd = libc::syscall(libc::SYS_pidfd_open, pid, 0);
        assert!(
            pidfd >= 0,
            "pidfd_open: {}",
            std::io::Error::last_os_error()
        );
        let fd = libc::syscall(libc::SYS_pidfd_getfd, pidfd as i32, 3, 0);
        assert!(fd >= 0, "pidfd_getfd: {}", std::io::Error::last_os_error());
        libc::close(pidfd as i32);
        <std::os::unix::net::UnixStream as std::os::fd::FromRawFd>::from_raw_fd(fd as i32)
    };
    let mut held = held;
    let wait = std::time::Duration::from_secs(4);
    let during = answered(&mut held, 71, &trace_dir, wait);

    let answer = call.await.unwrap();
    assert_eq!(
        answer.as_deref().map(str::trim),
        Ok("done"),
        "the call itself"
    );
    let after = answered(&mut held, 72, &trace_dir, wait);
    shutdown_daemon(&socket, &mut daemon).await;

    assert!(
        during,
        "vacuity guard: the held connection was not answered during the call"
    );
    assert!(!after, "a connection held past the call was still answered");
}

/// The scratch directories' parent must be the daemon user's alone: one
/// that others may enter is refused, and the call says why, rather than a
/// script running with its writable directory in a place another user can
/// reach or replace.
#[tokio::test(flavor = "multi_thread")]
async fn t_mcp_exec_script_refuses_a_scratch_parent_others_can_reach() {
    use std::os::unix::fs::PermissionsExt;
    let (_guard, root) = short_root("ct-scratch-");
    let server = server_binary();
    let replay = replay_server_for(&server);
    let trace_dir = simple_recording(&root);
    let (mut daemon, socket) = start_daemon(&server, &root, &replay).await;
    let mut mcp = start_mcp(&server, &root, &socket, &[]).await;
    // Where the daemon makes its scratch directories:
    // `<tmp_path>/script-scratch`, its tmp dir being the one the harness
    // gives it (`daemon_tmp_dir`), whatever CODETRACER_HOME this run inherits.
    let parent = daemon_tmp_dir(&root).join("script-scratch");
    std::fs::create_dir_all(&parent).unwrap();
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o755)).unwrap();
    let refused = mcp
        .call_tool(
            "exec_script",
            json!({"trace_path": trace_dir, "script": "print('ran')"}),
        )
        .await;
    // Negative control: the same call runs once the parent is private again.
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
    let ran = mcp
        .call_tool(
            "exec_script",
            json!({"trace_path": trace_dir, "script": "print('ran')"}),
        )
        .await;
    mcp.stop().await;
    shutdown_daemon(&socket, &mut daemon).await;
    match refused {
        Err(e) if e.contains("it must be its owner's alone") => {}
        other => panic!("a 0755 scratch parent was not refused: {other:?}"),
    }
    assert_eq!(ran.as_deref().map(str::trim), Ok("ran"));
}
