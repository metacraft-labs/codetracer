use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

#[test]
fn noir_flow_dap_variables_and_values() {
    let db_backend = find_db_backend();

    let project_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/noir");
    assert!(
        project_path.join("Nargo.toml").exists(),
        "Noir test project not found at {}",
        project_path.display()
    );

    // Check nargo availability
    if std::process::Command::new("nargo").arg("--version").output().is_err() {
        eprintln!("SKIPPED: nargo not found on PATH");
        return;
    }

    // Get nargo version for labeling
    let version_label = std::process::Command::new("nargo")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            s.lines()
                .next()
                .and_then(|line| line.split('=').nth(1))
                .map(|v| v.trim().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());

    // Record the trace — for Noir, source_path is the project directory
    let recording =
        TestRecording::create_db_trace(&project_path, Language::Noir, &version_label).expect("Noir recording failed");

    // For Noir, the actual source file is src/main.nr within the project dir.
    // nargo stores absolute paths, so suffix-match works.
    let breakpoint_source = project_path.join("src/main.nr");

    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        breakpoint_line: 13,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        // Noir reuses Rust grammar; println is not filtered as a macro in Noir
        excluded_identifiers: vec![],
        expected_values,
    };

    let mut runner = FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed");
    runner.run_and_verify(&config).expect("Noir flow test failed");
    runner.finish().expect("disconnect failed");
}
