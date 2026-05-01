//! DAP-level integration test that reproduces TODO 5.2(i):
//! Wasm DB-trace `Next` step does not advance the editor line.
//!
//! Two fixtures are exercised:
//!   - `src/db-backend/test-programs/wasm` — main() entry at line 20
//!   - `test-programs/wasm_example` (the GUI Playwright fixture) —
//!     main() entry at line 11
//!
//! The Playwright `wasm_example.spec.ts` test was failing because two
//! `clickNextButton` invocations left the editor on line 11.  Splitting
//! the failure between the protocol layer and the frontend showed:
//!   - The DAP `next` request advances correctly when issued from this
//!     test (proving the db-backend / replay logic is fine).
//!   - The GUI failure was a frontend bug: the IsoNim debug toolbar's
//!     click handlers were wired to a stub `DebugControlsVM` that the
//!     `initDebugControlsVMWithStore` call later replaced without
//!     re-applying the `onDapStep` bridge — every click silently
//!     dropped on the floor.  Plus the Playwright `clickDebugButton`
//!     helper mistakenly used `force:true` clicks (which still hit
//!     overlapping `lm_header` elements) instead of falling through
//!     directly to `dispatchEvent('click')`.
//!
//! This test guards against a regression in the DAP layer: if a future
//! refactor breaks `Next` for wasm DB traces, this test fails fast at
//! the protocol layer.

use std::path::{Path, PathBuf};
use std::time::Duration;

use ct_dap_client::client::DapStdioClient;
use ct_dap_client::protocol::DapMessage;
use ct_dap_client::types::launch::LaunchRequestArguments;
use serde_json::json;

mod test_harness;
use test_harness::{find_wazero, Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Reproduces TODO 5.2(i): two consecutive `Next` DAP commands on a
/// fresh wasm DB trace must advance the reported `location.line`.
#[test]
fn wasm_db_trace_next_advances_line() {
    run_wasm_next_test(&PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/wasm"));
}

/// Reproduces TODO 5.2(i) using the GUI-test wasm_example fixture
/// (the one tests/program_specific_tests/wasm_example.spec.ts records).
#[test]
fn wasm_example_db_trace_next_advances_line() {
    let workspace_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("expected codetracer workspace root above db-backend")
        .to_path_buf();
    let project_path = workspace_root.join("test-programs/wasm_example");
    if !project_path.join("Cargo.toml").exists() {
        eprintln!("SKIPPED: wasm_example fixture not found at {}", project_path.display());
        return;
    }
    run_wasm_next_test(&project_path);
}

fn run_wasm_next_test(project_path: &Path) {
    let db_backend = find_db_backend();

    assert!(
        project_path.join("Cargo.toml").exists(),
        "WASM test project not found at {}",
        project_path.display()
    );

    if find_wazero().is_none() {
        eprintln!("SKIPPED: wazero not found (set CODETRACER_WASM_VM_PATH or add wazero to PATH)");
        return;
    }
    let target_check = std::process::Command::new("rustup")
        .args(["target", "list", "--installed"])
        .output();
    if let Ok(output) = target_check {
        let targets = String::from_utf8_lossy(&output.stdout);
        if !targets.contains("wasm32-wasip1") {
            eprintln!("SKIPPED: wasm32-wasip1 target not installed (run: rustup target add wasm32-wasip1)");
            return;
        }
    }

    // Get wazero version for labeling
    let wazero_path = find_wazero().unwrap();
    let version_label = std::process::Command::new(&wazero_path)
        .arg("version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    let recording = TestRecording::create_db_trace(project_path, Language::RustWasm, &version_label)
        .expect("WASM recording failed");

    // Spawn db-backend, initialize, launch.
    let mut client = DapStdioClient::spawn(&db_backend).expect("spawn db-backend");
    let _caps = client.initialize().expect("initialize");

    client
        .launch(LaunchRequestArguments {
            trace_folder: Some(recording.trace_dir.clone()),
            ..Default::default()
        })
        .expect("launch");
    client.configuration_done().expect("configurationDone");
    client
        .wait_for_stopped(Duration::from_secs(30))
        .expect("first stopped event (run-to-entry)");

    // Capture the entry-point location via stackTrace.
    let entry_stack = client.stack_trace().expect("stackTrace at entry");
    assert!(
        !entry_stack.stack_frames.is_empty(),
        "stackTrace at entry returned no frames",
    );
    let entry_line = entry_stack.stack_frames[0].line;
    eprintln!("entry line: {entry_line}");

    // Send two consecutive `Next` requests via the standard DAP `next`
    // command (matches the `LayoutPage.clickNextButton` → DAP path used
    // by the GUI test in tests/program_specific_tests/wasm_example.spec.ts).
    let mut last_line = entry_line;
    let mut moved = false;
    for i in 0..2 {
        let move_state = step_next(&mut client).expect("step next");
        eprintln!(
            "after next #{i}: line={}, status={:?}",
            move_state.location.line, move_state.status
        );
        if move_state.location.line != last_line && move_state.location.line != 0 {
            moved = true;
        }
        last_line = move_state.location.line;
    }

    let _ = client.disconnect();

    assert!(
        moved,
        "Wasm DB-trace `Next` did not advance the reported source line \
         after two consecutive step requests (last_line={last_line}, entry_line={entry_line}). \
         This is TODO 5.2(i): the DAP `Next` request is a no-op on the wasm DB-trace path.",
    );
    assert_ne!(
        last_line, entry_line,
        "after two `Next` requests the location should have advanced past entry_line={entry_line}",
    );
}

/// Send a standard DAP `next` request and return the trailing
/// `ct/complete-move` event payload as a [`MoveState`].
///
/// Mirrors the production frontend path: `services/debugger_service.nim`
/// dispatches `"next"` over DAP, and the dap-server emits a
/// `ct/complete-move` event with the new step's location.  We drain
/// messages until we see the move event because the relative ordering
/// of `stopped`, `ct/complete-move`, and the trailing response is not
/// guaranteed.
fn step_next(
    client: &mut DapStdioClient,
) -> Result<ct_dap_client::types::navigation::MoveState, Box<dyn std::error::Error + Send + Sync>> {
    client.send_request("next", json!({"threadId": 1}))?;
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            return Err("timed out waiting for ct/complete-move".into());
        }
        match client.recv_message(remaining)? {
            DapMessage::Event(e) if e.event == "ct/complete-move" => {
                let state: ct_dap_client::types::navigation::MoveState = serde_json::from_value(e.body)?;
                return Ok(state);
            }
            DapMessage::Event(_) | DapMessage::Response(_) => continue,
            DapMessage::Request(_) => continue,
        }
    }
}
