//! `exec_script`'s caller-set timeout has a ceiling, and a script's output
//! is bounded.
//!
//! An MCP agent's tool arguments are model output, and a script is arbitrary
//! Python: without a ceiling one call could hold a Python process and a
//! replay for as long as it asked, and without a bound one script could make
//! the session manager and the server hold any amount of output.  Through the
//! real `trace mcp` and daemon:
//!
//! * `timeout_seconds` above 600, of 0, or not a number is refused by the
//!   server before the daemon is asked; 600 itself is accepted (the ceiling
//!   is inclusive);
//! * the daemon refuses a `ct/exec-script` whose `timeout` is above the
//!   ceiling from any client (asked directly on its socket, unconfined, so
//!   the refusal is the ceiling's);
//! * a script that writes more than 1 MiB to standard output, or to standard
//!   error, is stopped long before its timeout, its answer says so, and a
//!   process it started is killed with it;
//! * a process a script starts cannot leave the script's process group
//!   (`setsid` and `setpgid` are refused), so it is killed with the call, and
//!   the output it held open still comes back, promptly;
//! * a script has no core file, a 4 GiB address space and a 64 MiB file
//!   size;
//! * a script that writes 1000 bytes gets them all back (negative control).
//!
//! What is real: the MCP server, the daemon, the `replay-server`, the Python
//! API.  The recording is written by the production CTFS writer.  No
//! component is mocked.

#![cfg(target_os = "linux")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

#[path = "support/mcp_harness.rs"]
mod mcp_harness;

use std::path::Path;
use std::time::{Duration, Instant};

use mcp_harness::*;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// One DAP request on a fresh connection to the daemon, and its response.
async fn daemon_request(socket: &Path, command: &str, arguments: Value) -> Value {
    let mut stream = tokio::net::UnixStream::connect(socket).await.unwrap();
    let body = json!({"type": "request", "command": command, "seq": 41, "arguments": arguments})
        .to_string();
    stream
        .write_all(format!("Content-Length: {}\r\n\r\n{body}", body.len()).as_bytes())
        .await
        .unwrap();
    let mut bytes = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(found) = dap_messages(&bytes)
            .into_iter()
            .find(|m| m["type"] == "response" && m["request_seq"] == 41)
        {
            return found;
        }
        assert!(Instant::now() < deadline, "no response to {command}");
        let mut chunk = [0u8; 8192];
        let n = tokio::time::timeout(Duration::from_secs(30), stream.read(&mut chunk))
            .await
            .expect("the daemon answered")
            .unwrap();
        assert!(n > 0, "the daemon closed the connection");
        bytes.extend_from_slice(&chunk[..n]);
    }
}

fn pid_alive(pid: u32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
        && !std::fs::read_to_string(format!("/proc/{pid}/stat"))
            .unwrap_or_default()
            .contains(") Z ")
}

#[tokio::test(flavor = "multi_thread")]
async fn t_mcp_exec_script_timeout_and_output_are_bounded() {
    let (_guard, root) = short_root("ct-limits-");
    let server = server_binary();
    let replay = replay_server_for(&server);
    let workdir = root.join("work");
    std::fs::create_dir_all(&workdir).unwrap();
    let source = workdir.join("app.py");
    std::fs::write(&source, "def main():\n    return 0\n").unwrap();
    let trace = root.join("rec");
    std::fs::create_dir_all(&trace).unwrap();
    write_recording(&trace, &workdir, &source, &[]);

    let (mut daemon, socket) = start_daemon(&server, &root, &replay).await;
    let mut mcp = start_mcp(&server, &root, &socket, &[]).await;
    let mut failures: Vec<String> = Vec::new();

    // The ceiling, at the server.
    for timeout in [json!(601), json!(100000), json!(0), json!(-5), json!("60")] {
        match mcp
            .call_tool(
                "exec_script",
                json!({"trace_path": trace, "script": "print('ran')", "timeout_seconds": timeout}),
            )
            .await
        {
            Err(e) if e.contains("at most 600") => {}
            other => failures.push(format!("timeout_seconds {timeout}: {other:?}")),
        }
    }
    match mcp
        .call_tool(
            "exec_script",
            json!({"trace_path": trace, "script": "print('ran')", "timeout_seconds": 600}),
        )
        .await
    {
        Ok(out) if out.trim() == "ran" => {}
        other => failures.push(format!(
            "timeout_seconds 600 (the ceiling) was not accepted: {other:?}"
        )),
    }

    // The ceiling, at the daemon, for any client.
    let resp = daemon_request(
        &socket,
        "ct/exec-script",
        json!({"tracePath": trace, "script": "print('ran')", "timeout": 100000, "unconfinedScripts": true}),
    )
    .await;
    if resp["success"] != json!(false)
        || !resp["message"]
            .as_str()
            .unwrap_or_default()
            .contains("outside 1 to 600")
    {
        failures.push(format!("the daemon accepted timeout 100000: {resp}"));
    }

    // The output bound, on each stream, with a process the script started.
    for stream in ["stdout", "stderr"] {
        let script = format!(
            "import subprocess, sys, time\n\
             child = subprocess.Popen([sys.executable, '-I', '-c', 'import time; time.sleep(300)'])\n\
             print('CHILD', child.pid, flush=True)\n\
             for _ in range(48):\n    sys.{stream}.write('x' * 65536)\n    sys.{stream}.flush()\n\
             time.sleep(300)\n"
        );
        let started = Instant::now();
        let answer = mcp
            .call_tool(
                "exec_script",
                json!({"trace_path": trace, "script": script, "timeout_seconds": 120}),
            )
            .await;
        let took = started.elapsed();
        let text = match &answer {
            Err(e) => e.clone(),
            Ok(out) => {
                failures.push(format!(
                    "{stream}: a 3 MiB script was answered as a success"
                ));
                out.clone()
            }
        };
        if !text.contains("more than 1048576 bytes") {
            failures.push(format!(
                "{stream}: the answer does not say the script was stopped: {}",
                &text[..text.len().min(300)]
            ));
        }
        if took > Duration::from_secs(60) {
            failures.push(format!("{stream}: stopped only after {took:?}"));
        }
        if text.len() > 2 * 1024 * 1024 + 4096 {
            failures.push(format!("{stream}: the answer holds {} bytes", text.len()));
        }
        let child = text
            .split("CHILD ")
            .nth(1)
            .and_then(|rest| rest.split_whitespace().next())
            .and_then(|pid| pid.parse::<u32>().ok());
        match child {
            Some(pid) => {
                let deadline = Instant::now() + Duration::from_secs(10);
                while pid_alive(pid) && Instant::now() < deadline {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                if pid_alive(pid) {
                    failures.push(format!("{stream}: the script's child {pid} outlived it"));
                    unsafe { libc::kill(pid as i32, libc::SIGKILL) };
                }
            }
            None => failures.push(format!("{stream}: no child pid in the kept output")),
        }
    }

    // A process the script starts cannot leave its process group (setsid
    // and setpgid are refused), so the group kill reaches it; it holds the
    // script's output open, and the output still comes back, promptly.
    let script = "import os, sys, time\n\
         child = os.fork()\n\
         if child == 0:\n\
         \x20   for name, call in (('SETSID', os.setsid), ('SETPGID', lambda: os.setpgid(0, 0))):\n\
         \x20       try:\n\
         \x20           call()\n\
         \x20           print(name + '-ALLOWED', flush=True)\n\
         \x20       except PermissionError:\n\
         \x20           print(name + '-REFUSED', flush=True)\n\
         \x20   time.sleep(300)\n\
         \x20   os._exit(0)\n\
         time.sleep(1)\n\
         print('PARENT-DONE', 'CHILD', child, flush=True)\n";
    let started = Instant::now();
    let answer = mcp
        .call_tool(
            "exec_script",
            json!({"trace_path": trace, "script": script, "timeout_seconds": 120}),
        )
        .await;
    let took = started.elapsed();
    match &answer {
        Ok(out) => {
            for needle in ["SETSID-REFUSED", "SETPGID-REFUSED", "PARENT-DONE"] {
                if !out.contains(needle) {
                    failures.push(format!(
                        "the escape script's output lacks {needle}: {out:?}"
                    ));
                }
            }
            if took > Duration::from_secs(30) {
                failures.push(format!(
                    "the escape script was answered only after {took:?}"
                ));
            }
            match out
                .split("CHILD ")
                .nth(1)
                .and_then(|rest| rest.split_whitespace().next())
                .and_then(|pid| pid.parse::<u32>().ok())
            {
                Some(pid) => {
                    let deadline = Instant::now() + Duration::from_secs(10);
                    while pid_alive(pid) && Instant::now() < deadline {
                        tokio::time::sleep(Duration::from_millis(100)).await;
                    }
                    if pid_alive(pid) {
                        failures.push(format!("the escape script's child {pid} outlived the call"));
                        unsafe { libc::kill(pid as i32, libc::SIGKILL) };
                    }
                }
                None => failures.push(format!(
                    "no child pid in the escape script's output: {out:?}"
                )),
            }
        }
        Err(e) => failures.push(format!("the escape script failed: {e}")),
    }

    // Unconfined (a server started with --allow-unconfined-scripts), a
    // child can leave the group with setsid and hold the output open past
    // the call; the output the script wrote still comes back.
    let mut unconfined = start_mcp(&server, &root, &socket, &["--allow-unconfined-scripts"]).await;
    let script = "import os, time\n\
         child = os.fork()\n\
         if child == 0:\n\
         \x20   os.setsid()\n\
         \x20   time.sleep(60)\n\
         \x20   os._exit(0)\n\
         print('UNCONFINED-PARENT-DONE', 'CHILD', child, flush=True)\n";
    let started = Instant::now();
    match unconfined
        .call_tool(
            "exec_script",
            json!({"trace_path": trace, "script": script, "timeout_seconds": 120}),
        )
        .await
    {
        Ok(out) => {
            if !out.contains("UNCONFINED-PARENT-DONE") {
                failures.push(format!(
                    "the output held open by an escaped child was lost: {out:?}"
                ));
            }
            if let Some(pid) = out
                .split("CHILD ")
                .nth(1)
                .and_then(|rest| rest.split_whitespace().next())
                .and_then(|pid| pid.parse::<i32>().ok())
            {
                unsafe { libc::kill(pid, libc::SIGKILL) };
            }
        }
        Err(e) => failures.push(format!("the unconfined escape script failed: {e}")),
    }
    if started.elapsed() > Duration::from_secs(30) {
        failures.push(format!(
            "the unconfined escape script was answered after {:?}",
            started.elapsed()
        ));
    }
    unconfined.stop().await;

    // The resource limits: no core file, a capped address space, a capped
    // file size (Python ignores SIGXFSZ, so the write fails with EFBIG).
    let script = "import resource\n\
         print('CORE', resource.getrlimit(resource.RLIMIT_CORE))\n\
         try:\n\
         \x20   block = bytearray(6 << 30)\n\
         \x20   print('AS-ALLOWED')\n\
         except MemoryError:\n\
         \x20   print('AS-REFUSED')\n\
         try:\n\
         \x20   with open('big.bin', 'wb') as f:\n\
         \x20       f.write(b'x' * (65 << 20))\n\
         \x20   print('FSIZE-ALLOWED')\n\
         except OSError as e:\n\
         \x20   print('FSIZE-REFUSED', e.errno)\n";
    match mcp
        .call_tool(
            "exec_script",
            json!({"trace_path": trace, "script": script, "timeout_seconds": 120}),
        )
        .await
    {
        Ok(out) => {
            for needle in ["CORE (0, 0)", "AS-REFUSED", "FSIZE-REFUSED 27"] {
                if !out.contains(needle) {
                    failures.push(format!(
                        "the limits script's output lacks {needle:?}: {out:?}"
                    ));
                }
            }
        }
        Err(e) => failures.push(format!("the limits script failed: {e}")),
    }

    // Negative control: 1000 bytes come back whole.
    match mcp
        .call_tool("exec_script", json!({"trace_path": trace, "script": "import sys; sys.stdout.write('y' * 1000)", "timeout_seconds": 60}))
        .await
    {
        Ok(out) if out.trim_end().len() == 1000 && out.trim_end().chars().all(|c| c == 'y') => {}
        other => failures.push(format!("1000 bytes did not come back whole: {:?}", other.map(|o| o.len()))),
    }

    mcp.stop().await;
    shutdown_daemon(&socket, &mut daemon).await;
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
