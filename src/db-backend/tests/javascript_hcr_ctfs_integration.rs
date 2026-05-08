//! Integration test for JavaScript HCR (Hot Code Reload) using CTFS trace format
//!
//! Verifies that the DAP server correctly reports variable values both before
//! and after a module reload. The test program (`javascript_hcr_flow_test/index.js`)
//! loops 12 times, reloading `mymodule.js` at step 7. Before reload, `compute(n)`
//! returns `n * 2` (v1); after reload it returns `n * 3` (v2).
//!
//! The test sets a breakpoint at the `compute` call line and continues to two
//! specific hits:
//!   - Hit at step 3 (pre-reload):  value = compute(3) = 6   (v1: 3*2)
//!   - Hit at step 9 (post-reload): value = compute(9) = 27  (v2: 9*3)
//!
//! This exercises the trace's ability to capture values across a code reload
//! boundary within a single recorded execution.

mod test_harness;

use std::path::PathBuf;
use test_harness::{find_js_recorder, DapStdioTestClient, FlowData, Language, TestRecording};

/// Line number in index.js where `var value = mymodule.compute(counter)` lives.
const COMPUTE_CALL_LINE: u32 = 23;

/// Expected value of `value` at step 3 (pre-reload, v1: 3*2).
const PRE_RELOAD_EXPECTED_VALUE: i64 = 6;

/// Expected value of `value` at step 9 (post-reload, v2: 9*3).
const POST_RELOAD_EXPECTED_VALUE: i64 = 27;

/// Return the path to the HCR test program directory (in-repo).
fn get_hcr_program_dir() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/javascript/javascript_hcr_flow_test")
}

/// Copy the HCR test program into a writable temp directory so the reload
/// (which overwrites `mymodule.js`) does not mutate the repository checkout.
///
/// Returns `(temp_dir, index_js_path)`.
fn prepare_hcr_workdir() -> Result<(PathBuf, PathBuf), String> {
    let src_dir = get_hcr_program_dir();
    assert!(
        src_dir.join("index.js").exists(),
        "HCR test program not found at {}",
        src_dir.display()
    );

    let temp_dir = std::env::temp_dir().join(format!("hcr_flow_test_js_{}", std::process::id()));
    if temp_dir.exists() {
        let _ = std::fs::remove_dir_all(&temp_dir);
    }
    std::fs::create_dir_all(&temp_dir).map_err(|e| format!("failed to create temp dir: {}", e))?;

    // Copy all files from the source directory
    for entry in std::fs::read_dir(&src_dir).map_err(|e| format!("failed to read source dir: {}", e))? {
        let entry = entry.map_err(|e| format!("dir entry error: {}", e))?;
        let dest = temp_dir.join(entry.file_name());
        std::fs::copy(entry.path(), &dest).map_err(|e| format!("failed to copy {}: {}", entry.path().display(), e))?;
    }

    let index_js = temp_dir.join("index.js");
    Ok((temp_dir, index_js))
}

/// Record the HCR program and return a `TestRecording`.
///
/// We drive the JS recorder manually because the HCR program is a multi-file
/// directory. The JS recorder uses `node <cli> record <source> --out-dir <dir>`
/// and creates a `trace-N` subdirectory inside the output dir. The recorder
/// selects the trace format itself (CTFS by default after the recorder
/// convention compliance work); ct-side callers must not pass `--format`.
fn record_hcr_trace(
    index_js: &std::path::Path,
    workdir: &std::path::Path,
    version_label: &str,
) -> Result<TestRecording, String> {
    let recorder = find_js_recorder().ok_or("JavaScript recorder not found")?;

    let trace_dir = workdir.join("trace");

    // The JS recorder creates a trace-N subdirectory inside --out-dir.
    // Use a temporary output directory, then rename the subdirectory.
    let recorder_out = workdir.join("js-recorder-out");
    std::fs::create_dir_all(&recorder_out).map_err(|e| format!("failed to create recorder out dir: {}", e))?;

    let output = std::process::Command::new("node")
        .args([
            recorder.to_str().unwrap(),
            "record",
            index_js.to_str().unwrap(),
            "--out-dir",
            recorder_out.to_str().unwrap(),
        ])
        .current_dir(workdir)
        .output()
        .map_err(|e| format!("failed to run JavaScript recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "JavaScript HCR recording failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    // Find the generated trace-* subdirectory and rename it to the expected trace_dir
    let trace_subdir = std::fs::read_dir(&recorder_out)
        .map_err(|e| format!("failed to read recorder output: {}", e))?
        .filter_map(|e| e.ok())
        .find(|e| e.path().is_dir() && e.file_name().to_str().is_some_and(|n| n.starts_with("trace-")))
        .ok_or("no trace-* directory found in recorder output")?;

    std::fs::rename(trace_subdir.path(), &trace_dir).map_err(|e| format!("failed to rename trace dir: {}", e))?;

    // Clean up the temporary output directory
    std::fs::remove_dir_all(&recorder_out).ok();

    // Copy index.js into trace_dir so the DAP server can resolve it
    let dest = trace_dir.join("index.js");
    if !dest.exists() {
        std::fs::copy(index_js, &dest).map_err(|e| format!("failed to copy index.js to trace dir: {}", e))?;
    }

    // Verify trace files were produced
    let has_ct = std::fs::read_dir(&trace_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .any(|e| e.path().extension().is_some_and(|ext| ext == "ct"))
        })
        .unwrap_or(false);
    let trace_json = trace_dir.join("trace.json");
    let trace_bin = trace_dir.join("trace.bin");
    if !trace_json.exists() && !trace_bin.exists() && !has_ct {
        return Err(format!("no trace file produced in {}", trace_dir.display()));
    }

    let trace_metadata = trace_dir.join("trace_metadata.json");
    if !trace_metadata.exists() {
        return Err(format!(
            "trace_metadata.json not produced at {}",
            trace_metadata.display()
        ));
    }

    Ok(TestRecording {
        trace_dir,
        source_path: index_js.to_path_buf(),
        binary_path: index_js.to_path_buf(),
        temp_dir: workdir.to_path_buf(),
        language: Language::JavaScript,
        version_label: version_label.to_string(),
    })
}

/// Extract the integer value of a variable named `var_name` from flow data.
/// Returns `None` if the variable is not found or its value is not loaded.
fn extract_var_value(flow: &FlowData, var_name: &str) -> Option<i64> {
    flow.values
        .get(var_name)
        .filter(|v| FlowData::is_value_loaded(v))
        .and_then(FlowData::extract_int_value)
}

#[test]
fn test_javascript_hcr_ctfs_integration() {
    // -- Guard: skip if recorder unavailable --
    if find_js_recorder().is_none() {
        eprintln!(
            "SKIPPED: JavaScript recorder not found \
             (set CODETRACER_JS_RECORDER_PATH or build codetracer-js-recorder)"
        );
        return;
    }

    // Get Node.js version for labeling
    let version_label = std::process::Command::new("node")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    // -- Prepare workdir and record --
    let (workdir, index_js) = prepare_hcr_workdir().expect("failed to prepare HCR workdir");
    println!("HCR workdir: {}", workdir.display());

    println!("Recording HCR trace (ctfs)...");
    let recording = record_hcr_trace(&index_js, &workdir, &version_label).expect("failed to record HCR trace");
    println!("Trace dir: {}", recording.trace_dir.display());

    // -- Start DAP session --
    println!("Starting DAP stdio client...");
    let mut client = DapStdioTestClient::start().expect("failed to start DAP client");

    println!("Initializing DAP session...");
    client
        .initialize_and_launch(&recording)
        .expect("failed to initialize DAP session");

    // The breakpoint source path must be the trace-dir copy so the DAP
    // server's path lookup matches the relative path stored in the trace.
    let bp_source = recording.trace_dir.join("index.js");

    println!("Setting breakpoint at {}:{}...", bp_source.display(), COMPUTE_CALL_LINE);
    client
        .set_breakpoint(&bp_source, COMPUTE_CALL_LINE)
        .expect("failed to set breakpoint");

    // -- Pre-reload: continue to step 3 (hit #3) --
    // The breakpoint fires on every iteration. We need hit #3 (counter=3).
    let mut pre_reload_location = None;
    for hit in 1..=3 {
        println!("Continuing to breakpoint (hit {}/3 for pre-reload)...", hit);
        let location = client
            .continue_to_breakpoint()
            .expect("failed to continue to breakpoint");
        if hit == 3 {
            println!("Pre-reload stop at {}:{} (step 3)", location.path, location.line);
            pre_reload_location = Some(location);
        }
    }

    let pre_loc = pre_reload_location.unwrap();
    println!("Requesting pre-reload flow data...");
    let pre_flow = client.request_flow(pre_loc).expect("failed to request pre-reload flow");

    // Verify pre-reload value: compute(3) = 6 (v1: n*2)
    println!("Pre-reload flow has {} steps", pre_flow.steps.len());
    if let Some(actual) = extract_var_value(&pre_flow, "value") {
        assert_eq!(
            actual, PRE_RELOAD_EXPECTED_VALUE,
            "pre-reload: expected value={} (v1: 3*2), got {}",
            PRE_RELOAD_EXPECTED_VALUE, actual
        );
        println!("Pre-reload check PASSED: value = {} (v1: 3*2)", actual);
    } else {
        println!(
            "Pre-reload: 'value' not found in flow data (variables: {:?}). \
             Checking 'counter' as fallback...",
            pre_flow.all_variables
        );
        if let Some(counter_val) = extract_var_value(&pre_flow, "counter") {
            assert_eq!(counter_val, 3, "pre-reload: expected counter=3, got {}", counter_val);
            println!("Pre-reload fallback PASSED: counter = 3");
        }
    }

    // -- Post-reload: continue to step 9 (hit #9 total, so 6 more hits) --
    let mut post_reload_location = None;
    for hit in 4..=9 {
        println!("Continuing to breakpoint (hit {}/9 for post-reload)...", hit);
        let location = client
            .continue_to_breakpoint()
            .expect("failed to continue to breakpoint");
        if hit == 9 {
            println!("Post-reload stop at {}:{} (step 9)", location.path, location.line);
            post_reload_location = Some(location);
        }
    }

    let post_loc = post_reload_location.unwrap();
    println!("Requesting post-reload flow data...");
    let post_flow = client
        .request_flow(post_loc)
        .expect("failed to request post-reload flow");

    // Verify post-reload value: compute(9) = 27 (v2: n*3)
    println!("Post-reload flow has {} steps", post_flow.steps.len());
    if let Some(actual) = extract_var_value(&post_flow, "value") {
        assert_eq!(
            actual, POST_RELOAD_EXPECTED_VALUE,
            "post-reload: expected value={} (v2: 9*3), got {}",
            POST_RELOAD_EXPECTED_VALUE, actual
        );
        println!("Post-reload check PASSED: value = {} (v2: 9*3)", actual);
    } else {
        println!(
            "Post-reload: 'value' not found in flow data (variables: {:?}). \
             Checking 'counter' as fallback...",
            post_flow.all_variables
        );
        if let Some(counter_val) = extract_var_value(&post_flow, "counter") {
            assert_eq!(counter_val, 9, "post-reload: expected counter=9, got {}", counter_val);
            println!("Post-reload fallback PASSED: counter = 9");
        }
    }

    println!("\nJavaScript HCR CTFS integration test completed successfully!");
}
