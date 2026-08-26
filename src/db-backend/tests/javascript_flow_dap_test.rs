use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording, find_js_recorder};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Require the JavaScript recorder, or fail loudly.
///
/// `codetracer-js-recorder` is a **required** sibling for these suites
/// (`ci/test/ct-providers.sh`), so its absence is an environment error
/// rather than a reason to report success. Silently skipping is how the
/// JS locals tests stayed green for the whole lifetime of issue #602 —
/// the recorder was missing from CI, the tests returned early, and the
/// broken State panel went unnoticed.
///
/// `CT_PROVIDERS_ALLOW_MISSING=1` is the documented escape hatch (see
/// the repo CLAUDE.md) for running the suite without the recorder
/// siblings; only then do we skip. Returns `true` when the caller should
/// proceed.
fn require_js_recorder() -> bool {
    if find_js_recorder().is_some() {
        return true;
    }
    if std::env::var("CT_PROVIDERS_ALLOW_MISSING").is_ok() {
        eprintln!(
            "SKIPPED (CT_PROVIDERS_ALLOW_MISSING=1): JavaScript recorder not found; \
             set CODETRACER_JS_RECORDER_PATH or build codetracer-js-recorder"
        );
        return false;
    }
    panic!(
        "codetracer-js-recorder not found — it is a REQUIRED sibling for this suite. \
         Set CODETRACER_JS_RECORDER_PATH, put codetracer-js-recorder on PATH, or set \
         CT_PROVIDERS_ALLOW_MISSING=1 to skip."
    );
}

/// Build the trace-directory label for one test in this file.
///
/// `TestRecording::create_db_trace` derives its temp directory from
/// `(language, format, version_label, pid, source-path hash)`. Both tests
/// in this file record the *same* source from the *same* process, so with
/// a bare Node version label they resolve to the same directory and race:
/// whichever test gets there second finds the recorder output already
/// renamed away and fails with "failed to rename trace dir". Folding the
/// test name into the label keeps the two recordings apart.
fn trace_label(test_name: &str) -> String {
    let node_version = std::process::Command::new("node")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());
    format!("{node_version}-{test_name}")
}

#[test]
fn javascript_flow_dap_variables_and_values() {
    if !require_js_recorder() {
        return;
    }

    let db_backend = find_db_backend();

    let source_path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/javascript/javascript_flow_test.js");
    assert!(
        source_path.exists(),
        "JavaScript test program not found at {}",
        source_path.display()
    );

    let version_label = trace_label("variables_and_values");

    // Record the trace
    let recording = TestRecording::create_db_trace(&source_path, Language::JavaScript, &version_label)
        .expect("JavaScript recording failed");

    // The JS recorder emits variable names in exprOrder (via tree-sitter)
    // but only populates beforeValues for the most recent assignment at each
    // step. Verify variable extraction without checking specific int values.
    let expected_values = HashMap::new();

    let config = FlowTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line: 11,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["console".to_string(), "calculate_sum".to_string()],
        expected_values,
    };

    let mut runner = FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed");
    runner.run_and_verify(&config).expect("JavaScript flow test failed");
    runner.finish().expect("disconnect failed");
}

#[test]
fn test_js_locals_all_statements() {
    if !require_js_recorder() {
        return;
    }

    let db_backend = find_db_backend();

    let source_path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/javascript/javascript_flow_test.js");
    assert!(
        source_path.exists(),
        "JavaScript test program not found at {}",
        source_path.display()
    );

    let version_label = trace_label("locals_all_statements");

    let recording = TestRecording::create_db_trace(&source_path, Language::JavaScript, &version_label)
        .expect("JavaScript recording failed");

    // Line 11 is the first statement inside calculate_sum.
    // We expect all local variables to have their propagated values verified as we step through.
    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line: 11,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["console".to_string(), "calculate_sum".to_string()],
        expected_values,
    };

    let mut runner = FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed");
    runner.run_and_verify(&config).expect("JavaScript flow test failed");
    runner.finish().expect("disconnect failed");
}
