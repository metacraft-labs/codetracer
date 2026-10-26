//! A launched session opens at its start geid (`CODETRACER_START_GEID`).
//!
//! `ct host --manifest` exports the manifest's `replay_start.geid` as
//! `CODETRACER_START_GEID`, and the replay agent sets the same variable for a
//! hosted replay; the hosted session's `replay-server` inherits it and the
//! launch opens there instead of at the recording's entry
//! (codetracer-pm `spec/CLI/ct/host.md`, "The start position";
//! `Handler::run_to_launch_position`).
//!
//! `launch_opens_at_the_start_geid_native_recording` records
//! `backend-manager/tests/fixtures/native/span_goto_probe.c` with `ct-mcr
//! record`, which prints each span's end-marker geid, the value the span
//! computed and the source line of its end call (`__LINE__`). Then, over
//! `replay-server dap-server --stdio`:
//!
//! 1. with no start geid, the launch stops somewhere that is not span 2's
//!    end marker (the control: where an unpositioned session opens);
//! 2. with `CODETRACER_START_GEID` = span 2's end-marker geid, the one
//!    `ct/complete-move` of the launch is at the probe's end-call line, at
//!    the position the replay reports after a marker (its geid plus one,
//!    debugserver.md `qCTGetTime`), the stack's first frame is there, and no
//!    error notification names the variable;
//! 3. with `CODETRACER_START_GEID=1`, a geid the replay refuses (`E09`: no
//!    position of the served thread), the session opens where the control
//!    did and an error notification names the variable, its value and the
//!    replay's reason.
//!
//! The oracles are the program's own output (the geids the recorder answered,
//! `__LINE__`), never a value this test chose. The recording uses MCR's
//! default attach, so it needs a host with CPUID faulting
//! (Multi-Core-Recorder.md §8.3); the recorder runs with every
//! `CT_*_DEBUG_*` variable removed, so on a host without it the recording is
//! refused and the test fails.
//!
//! `launch_with_a_malformed_start_geid_opens_at_the_entry_and_says_so` runs
//! on any host: the committed materialized fixture
//! `tests/fixtures/span_stream/web_session.ct`, launched with a value that is
//! not a geid, opens where it opens without one, and an error notification
//! names the variable and the value.
//!
//! `materialized_launch_with_a_start_geid_opens_at_the_entry_quietly` runs on
//! any host too: the same fixture launched with well-formed geids (`0`, the
//! first step a materialized trace's correlation index can name, and a large
//! one) opens where it opens without one and sends no error notification. A
//! materialized trace's replay has no geid positions, and the replay agent
//! and `ct host` pass a dive-in's geid for every recording kind, so a launch
//! that tried to seek there would greet every materialized dive-in with a
//! refusal.
//!
//! No mocks: the recorder, `replay-server`, `ct-native-replay` and `ct-mcr
//! debugserver` are the shipping binaries and the client speaks DAP over
//! stdio. A missing prerequisite (`ct-mcr`, `ct-native-replay`, a C
//! compiler) is reported through `skip_or_fail_missing_prerequisite`, which
//! fails under `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false`.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use ct_dap_client::client::DapStdioClient;
use ct_dap_client::protocol::DapMessage;
use ct_dap_client::types::launch::LaunchRequestArguments;
use serde_json::{Value, json};

mod test_harness;

const START_GEID_ENV: &str = "CODETRACER_START_GEID";

fn replay_server() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Where a launched session stopped and what it said while doing so.
#[derive(Debug)]
struct Opened {
    /// The first `ct/complete-move`'s `location`.
    location: Value,
    /// The `stackTrace` frames at that stop.  Only the native case, which
    /// compiles on x86_64 Linux alone, reads them.
    #[cfg_attr(not(all(target_os = "linux", target_arch = "x86_64")), allow(dead_code))]
    frames: Vec<Value>,
    /// The texts of every `ct/notification` of kind error (2).
    errors: Vec<String>,
}

impl Opened {
    fn line(&self) -> i64 {
        self.location["line"].as_i64().unwrap_or(-1)
    }
    fn position(&self) -> i64 {
        self.location["rrTicks"].as_i64().unwrap_or(-1)
    }
    fn path(&self) -> String {
        self.location["path"].as_str().unwrap_or("").to_string()
    }
}

/// Launch `trace` the way a front end does (`initialize`, `launch`,
/// `configurationDone`), with `envs` on the replay-server, and read where
/// the launch stopped.
fn open(trace: &Path, worker: Option<&Path>, envs: &[(&str, &str)]) -> Opened {
    let mut client = DapStdioClient::spawn_with_envs(&replay_server(), envs).expect("spawn replay-server");
    client.initialize().expect("initialize");
    client
        .launch(LaunchRequestArguments {
            trace_folder: Some(trace.to_path_buf()),
            ct_rr_worker_exe: worker.map(Path::to_path_buf),
            ..Default::default()
        })
        .expect("launch");
    client.configuration_done().expect("configurationDone");

    let mut location = None;
    let mut errors = Vec::new();
    let mut events = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(300);
    // Read until the launch's stop, then a little longer: its notifications
    // follow the stop.
    let mut settle: Option<Instant> = None;
    loop {
        let now = Instant::now();
        let until = settle.unwrap_or(deadline);
        if now >= until {
            break;
        }
        match client.recv_message(until - now) {
            Ok(DapMessage::Event(event)) => {
                events.push(event.event.clone());
                if event.event == "ct/complete-move" && location.is_none() {
                    location = Some(event.body["location"].clone());
                    settle = Some(Instant::now() + Duration::from_secs(2));
                } else if event.event == "ct/notification" && event.body["kind"].as_i64() == Some(2) {
                    errors.push(event.body["text"].as_str().unwrap_or("").to_string());
                }
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    let location = location.unwrap_or_else(|| {
        panic!(
            "the launch of {} never stopped; events {events:?}; errors {errors:?}",
            trace.display()
        )
    });
    client
        .send_request("stackTrace", json!({"threadId": 1}))
        .expect("stackTrace");
    let mut frames = Vec::new();
    let end = Instant::now() + Duration::from_secs(60);
    while Instant::now() < end {
        match client.recv_message(end - Instant::now()) {
            Ok(DapMessage::Response(response)) if response.command == "stackTrace" => {
                frames = response.body["stackFrames"].as_array().cloned().unwrap_or_default();
                break;
            }
            Ok(DapMessage::Event(event))
                if event.event == "ct/notification" && event.body["kind"].as_i64() == Some(2) =>
            {
                errors.push(event.body["text"].as_str().unwrap_or("").to_string());
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    let _ = client.disconnect();
    Opened {
        location,
        frames,
        errors,
    }
}

fn start_geid_errors(opened: &Opened) -> Vec<&String> {
    opened
        .errors
        .iter()
        .filter(|text| text.contains(START_GEID_ENV))
        .collect()
}

#[test]
fn launch_with_a_malformed_start_geid_opens_at_the_entry_and_says_so() {
    let trace = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/span_stream/web_session.ct");
    assert!(trace.is_file(), "the committed fixture {} is missing", trace.display());
    let control = open(&trace, None, &[]);
    assert!(
        start_geid_errors(&control).is_empty(),
        "no start geid, no complaint about one: {:?}",
        control.errors
    );
    let malformed = open(&trace, None, &[(START_GEID_ENV, "12x")]);
    assert_eq!(
        (malformed.path(), malformed.line(), malformed.position()),
        (control.path(), control.line(), control.position()),
        "a malformed start geid leaves the session where an unpositioned launch opens"
    );
    let refused = start_geid_errors(&malformed);
    assert!(
        refused.len() == 1 && refused[0].contains("\"12x\"") && refused[0].contains("not an unsigned integer"),
        "one error notification names the variable and the value: {:?}",
        malformed.errors
    );
}

#[test]
fn materialized_launch_with_a_start_geid_opens_at_the_entry_quietly() {
    let trace = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/span_stream/web_session.ct");
    assert!(trace.is_file(), "the committed fixture {} is missing", trace.display());
    let control = open(&trace, None, &[]);
    for geid in ["0", "120045"] {
        let opened = open(&trace, None, &[(START_GEID_ENV, geid)]);
        assert_eq!(
            (opened.path(), opened.line(), opened.position()),
            (control.path(), control.line(), control.position()),
            "a materialized trace launched with {START_GEID_ENV}={geid} opens where an unpositioned launch opens"
        );
        assert!(
            opened.errors.is_empty(),
            "a materialized trace launched with {START_GEID_ENV}={geid} reported errors: {:?}",
            opened.errors
        );
    }
}

/// The span probe's printed spans: (end-marker geid, value, end-call line).
/// Used by the native case only, so compiled where it is.
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn printed_spans(stdout: &str) -> Vec<(u64, i64, i64)> {
    stdout
        .lines()
        .filter_map(|line| {
            let words: Vec<&str> = line.split_whitespace().collect();
            if words.len() == 10 && words[0] == "span" && words[2] == "start" {
                Some((words[5].parse().ok()?, words[7].parse().ok()?, words[9].parse().ok()?))
            } else {
                None
            }
        })
        .collect()
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
#[test]
fn launch_opens_at_the_start_geid_native_recording() {
    let name = "launch_opens_at_the_start_geid_native_recording";
    let Some(worker) = test_harness::find_ct_native_replay() else {
        test_harness::skip_or_fail_missing_prerequisite(
            name,
            "ct-native-replay was not found",
            "build it with `just ensure-ct-native-replay` or set CT_NATIVE_REPLAY_PATH",
        );
        return;
    };
    let Some(ct_mcr) = test_harness::find_ct_mcr() else {
        test_harness::skip_or_fail_missing_prerequisite(
            name,
            "the MCR recorder CLI (ct-mcr / ct_cli / CODETRACER_CT_MCR_CMD) was not found",
            "build it with `just build-ct-mcr` in codetracer-native-recorder and set CODETRACER_CT_MCR_CMD",
        );
        return;
    };
    let dir = std::env::temp_dir().join(format!("ct-start-geid-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    let source =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../backend-manager/tests/fixtures/native/span_goto_probe.c");
    let binary = dir.join("span_goto_probe");
    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".to_owned());
    // `-z now`: the stage0 emulator replay does not execute the lazy-binding
    // resolver's XSAVEC (see the fixture's header).
    let compiled = std::process::Command::new(&cc)
        .args(["-O0", "-g", "-U_FORTIFY_SOURCE", "-Wl,-z,now", "-o"])
        .arg(&binary)
        .arg(&source)
        .arg("-lpthread")
        .output();
    let compiled = match compiled {
        Ok(output) => output,
        Err(e) => {
            test_harness::skip_or_fail_missing_prerequisite(
                name,
                &format!("no C compiler ({cc}): {e}"),
                "run inside the codetracer dev shell",
            );
            return;
        }
    };
    assert!(
        compiled.status.success(),
        "compiling the span probe failed: {}",
        String::from_utf8_lossy(&compiled.stderr)
    );

    // Hermetic: the recorder's debug knobs are removed, so a host without
    // CPUID faulting refuses the recording and the test fails.
    let trace = dir.join("span_goto_probe.ct");
    let mut record = std::process::Command::new(&ct_mcr);
    for (key, _) in std::env::vars_os() {
        let key = key.to_string_lossy().into_owned();
        if key.starts_with("CT_") && key.contains("_DEBUG_") {
            record.env_remove(&key);
        }
    }
    // The recording's licensing counter (`state.db`) goes to a scratch
    // `CODETRACER_HOME`, never the developer's own profile. That variable
    // outranks `HOME`/`XDG_DATA_HOME` for every CodeTracer location
    // (`libs/ct-home`), so redirecting those instead would not isolate it.
    let recorded = record
        .current_dir(&dir)
        .env("CODETRACER_HOME", dir.join("ct-home"))
        .args(["record", "-o"])
        .arg(&trace)
        .arg("--")
        .arg(&binary)
        .output()
        .expect("run ct-mcr record");
    let stdout = String::from_utf8_lossy(&recorded.stdout).into_owned();
    assert!(
        recorded.status.success() && stdout.contains("span 2 "),
        "ct-mcr record did not record the span probe (exit {:?}); recording needs a host with \
         CPUID faulting (Multi-Core-Recorder.md §8.3).\nstdout:\n{stdout}\nstderr:\n{}",
        recorded.status.code(),
        String::from_utf8_lossy(&recorded.stderr)
    );
    let spans = printed_spans(&stdout);
    assert_eq!(spans.len(), 3, "the probe printed three spans: {stdout}");
    let (end, _value, end_line) = spans[1];
    let ct_mcr_text = ct_mcr.to_string_lossy().into_owned();
    let run = |geid: Option<&str>| {
        let mut pairs: Vec<(&str, &str)> = vec![("CODETRACER_CT_MCR_CMD", ct_mcr_text.as_str())];
        if let Some(geid) = geid {
            pairs.push((START_GEID_ENV, geid));
        }
        open(&trace, Some(&worker), &pairs)
    };

    // 1. The control: where an unpositioned launch opens.
    let control = run(None);
    eprintln!(
        "span 2: end marker {end}, line {end_line}; control at {}:{} position {}",
        control.path(),
        control.line(),
        control.position()
    );
    assert!(
        control.position() != (end + 1) as i64 && start_geid_errors(&control).is_empty(),
        "the control opened at span 2's marker already, or complained: {control:?}"
    );

    // 2. At span 2's end marker.
    let at_marker = run(Some(&end.to_string()));
    assert!(
        start_geid_errors(&at_marker).is_empty(),
        "the start geid was refused: {:?}",
        at_marker.errors
    );
    assert!(
        at_marker.path().ends_with("span_goto_probe.c") && at_marker.line() == end_line,
        "the session opened at {}:{}, not at the probe's end call (span_goto_probe.c:{end_line})",
        at_marker.path(),
        at_marker.line()
    );
    assert_eq!(
        at_marker.position(),
        (end + 1) as i64,
        "after span 2's end marker (geid {end}) the replay is at the recorder call's own event"
    );
    let first = at_marker.frames.first().cloned().unwrap_or(Value::Null);
    assert!(
        first["line"].as_i64() == Some(end_line)
            && first["source"]["path"]
                .as_str()
                .is_some_and(|p| p.ends_with("span_goto_probe.c")),
        "the stack starts at the probe's end call: {:?}",
        at_marker.frames
    );

    // 3. A geid the replay refuses: the entry, and an error naming it.
    let refused = run(Some("1"));
    assert_eq!(
        (refused.path(), refused.line(), refused.position()),
        (control.path(), control.line(), control.position()),
        "a refused start geid leaves the session where an unpositioned launch opens"
    );
    let named = start_geid_errors(&refused);
    assert!(
        named.len() == 1
            && named[0].contains("CODETRACER_START_GEID=1 could not be reached")
            && named[0].contains("E09"),
        "one error notification names the variable, its value and the replay's reason: {:?}",
        refused.errors
    );
    let _ = std::fs::remove_dir_all(&dir);
}
