use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestRunner, StepAction, SteppingTestConfig};

mod test_harness;
use test_harness::{Language, TestRecording, find_php_recorder};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

#[test]
fn test_php_debugger_line_jump() {
    if !test_harness::is_command_available("php") {
        eprintln!("SKIPPED: php is not available on PATH");
        return;
    }

    if find_php_recorder().is_none() {
        eprintln!("SKIPPED: PHP recorder not found");
        return;
    }

    let db_backend = find_db_backend();

    let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/php/php_flow_test.php");
    assert!(
        source_path.exists(),
        "PHP test program not found at {}",
        source_path.display()
    );

    // Get PHP version for labeling
    let version_label = std::process::Command::new("php")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.split_whitespace().nth(1).map(|v| v.to_string()))
        .unwrap_or_else(|| "unknown".to_string());

    // Record the trace
    let recording =
        TestRecording::create_db_trace(&source_path, Language::Php, &version_label).expect("PHP recording failed");

    // Breakpoint at line 6 (entry of calculate_sum).
    // The C extension registers a step event at function entry, which corresponds to line 6.
    let config = SteppingTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line: 6,
        steps: vec![
            // Landing line at breakpoint should be line 6
            (StepAction::Next, 6),
        ],
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for PHP trace");
    runner
        .run_stepping_test(&config)
        .expect("PHP stepping/line jump test failed");
    runner.finish().expect("disconnect failed");

    println!("PHP DAP line jump test passed!");
}
