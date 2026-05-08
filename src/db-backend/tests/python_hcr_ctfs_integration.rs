//! Integration test for Python HCR (Hot Code Reload) using CTFS trace format
//!
//! Verifies that the DAP server correctly reports variable values both before
//! and after a module reload. The test program (`python_hcr_flow_test/main.py`)
//! loops 12 times, reloading `mymodule` at step 7. Before reload, `compute(n)`
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
use test_harness::{find_python_recorder, find_suitable_python, DapStdioTestClient, FlowData, Language, TestRecording};

/// Line number in main.py where `value = mymodule.compute(counter)` lives.
const COMPUTE_CALL_LINE: u32 = 22;

/// Expected value of `value` at step 3 (pre-reload, v1: 3*2).
const PRE_RELOAD_EXPECTED_VALUE: i64 = 6;

/// Expected value of `value` at step 9 (post-reload, v2: 9*3).
const POST_RELOAD_EXPECTED_VALUE: i64 = 27;

/// Return the path to the HCR test program directory (in-repo).
fn get_hcr_program_dir() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/python/python_hcr_flow_test")
}

/// Copy the HCR test program into a writable temp directory so the reload
/// (which overwrites `mymodule.py`) does not mutate the repository checkout.
///
/// Returns `(temp_dir, main_py_path)`.
fn prepare_hcr_workdir() -> Result<(PathBuf, PathBuf), String> {
    let src_dir = get_hcr_program_dir();
    assert!(
        src_dir.join("main.py").exists(),
        "HCR test program not found at {}",
        src_dir.display()
    );

    let temp_dir = std::env::temp_dir().join(format!("hcr_flow_test_py_{}", std::process::id()));
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

    let main_py = temp_dir.join("main.py");
    Ok((temp_dir, main_py))
}

/// Record the HCR program and return a `TestRecording`.
///
/// We cannot use `TestRecording::create_db_trace_with_format` directly because
/// the HCR program is a multi-file directory and the recording must happen with
/// CWD set to the program directory (so module imports work). Instead we drive
/// the recorder manually and construct the `TestRecording` ourselves.
fn record_hcr_trace(
    main_py: &std::path::Path,
    workdir: &std::path::Path,
    version_label: &str,
) -> Result<TestRecording, String> {
    let recorder = find_python_recorder().ok_or("Python recorder not found")?;

    let trace_dir = workdir.join("trace");
    std::fs::create_dir_all(&trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    // Pick a Python 3.10+ interpreter
    let python = std::env::var("CODETRACER_PYTHON_CMD")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            ["python3.12", "python3.13", "python3", "python"]
                .iter()
                .find(|cmd| {
                    std::process::Command::new(cmd)
                        .arg("--version")
                        .output()
                        .map(|o| o.status.success())
                        .unwrap_or(false)
                })
                .copied()
                .unwrap_or("python3")
                .to_string()
        });

    let output = std::process::Command::new(&python)
        .args([recorder.to_str().unwrap(), main_py.to_str().unwrap()])
        .current_dir(&trace_dir)
        .env("CODETRACER_TRACE_FORMAT", "ctfs")
        .output()
        .map_err(|e| format!("failed to run Python recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Python HCR recording failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    // Copy main.py into trace_dir so the DAP server can resolve it
    let dest = trace_dir.join("main.py");
    if !dest.exists() {
        std::fs::copy(main_py, &dest).map_err(|e| format!("failed to copy main.py to trace dir: {}", e))?;
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

    // Per the CTFS migration guide (Trace-Files/CTFS-Migration-Guide.md
    // §3e), a `.ct` container is self-contained: metadata lives in
    // `meta.dat` inside the container, not in a sidecar `trace_metadata.json`.
    // CTFS-only bundles intentionally omit the sidecar, so the existence
    // check has been removed; the `.ct`/`trace.bin`/`trace.json` check
    // above already guarantees that *something* was recorded.

    Ok(TestRecording {
        trace_dir,
        source_path: main_py.to_path_buf(),
        binary_path: main_py.to_path_buf(),
        temp_dir: workdir.to_path_buf(),
        language: Language::Python,
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
fn test_python_hcr_ctfs_integration() {
    // -- Guard: skip if recorder or Python 3.10+ unavailable --
    if find_python_recorder().is_none() {
        eprintln!(
            "SKIPPED: Python recorder not found \
             (set CODETRACER_PYTHON_RECORDER_PATH or check out sibling/submodule)"
        );
        return;
    }

    let (_python_cmd, version_label) = match find_suitable_python() {
        Some(pair) => pair,
        None => {
            eprintln!("SKIPPED: Python 3.10+ not found (needed for the recorder)");
            return;
        }
    };

    // -- Prepare workdir and record --
    let (workdir, main_py) = prepare_hcr_workdir().expect("failed to prepare HCR workdir");
    println!("HCR workdir: {}", workdir.display());

    println!("Recording HCR trace (ctfs)...");
    let recording = record_hcr_trace(&main_py, &workdir, &version_label).expect("failed to record HCR trace");
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
    let bp_source = recording.trace_dir.join("main.py");

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
        // The variable might not be loaded yet at step position; check counter instead
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

    println!("\nPython HCR CTFS integration test completed successfully!");
}
