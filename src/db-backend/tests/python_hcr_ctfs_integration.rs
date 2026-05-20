//! Integration test for Python HCR (Hot Code Reload) using the CTFS trace format.
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
//!
//! Materialized traces are CTFS-only: the recorder driven here is the
//! Rust-backed `codetracer_python_recorder` Python module, which writes a
//! single `.ct` container — the legacy pure-Python `trace.py` recorder is
//! no longer auto-detected because db-backend has dropped support for the
//! `trace.json` / `trace_metadata.json` / `trace_paths.json` 3-file layout.

mod test_harness;

use std::path::PathBuf;
use test_harness::{
    DapStdioTestClient, FlowData, Language, RUST_PYTHON_RECORDER_MODULE_SENTINEL, TestRecording, find_python_recorder,
    find_suitable_python,
};

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
/// the Rust-backed recorder manually and construct the `TestRecording`
/// ourselves.
fn record_hcr_trace(
    main_py: &std::path::Path,
    workdir: &std::path::Path,
    version_label: &str,
) -> Result<TestRecording, String> {
    let recorder = find_python_recorder().ok_or(
        "Python recorder not found. Install the Rust-backed \
         `codetracer_python_recorder` Python module \
         (sibling repo `codetracer-python-recorder`) or set \
         CODETRACER_PYTHON_RECORDER_PATH to a CTFS-emitting recorder.",
    )?;

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

    let mut cmd = std::process::Command::new(&python);
    if recorder.to_str() == Some(RUST_PYTHON_RECORDER_MODULE_SENTINEL) {
        // Drive the Rust-backed recorder via its module entry point.
        cmd.args([
            "-m",
            "codetracer_python_recorder",
            "--out-dir",
            trace_dir.to_str().unwrap(),
            main_py.to_str().unwrap(),
        ]);
    } else {
        // Explicit override path (still required to be CTFS-emitting).
        cmd.args([recorder.to_str().unwrap(), main_py.to_str().unwrap()]);
    }
    let output = cmd
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

    // Copy main.py into trace_dir so the DAP server can resolve it via the
    // workdir-relative paths the recorder stored.
    let dest = trace_dir.join("main.py");
    if !dest.exists() {
        std::fs::copy(main_py, &dest).map_err(|e| format!("failed to copy main.py to trace dir: {}", e))?;
    }

    // Verify the recorder produced a CTFS container — the only supported
    // materialized-trace format.
    let ct_count = std::fs::read_dir(&trace_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter(|e| e.path().extension().is_some_and(|ext| ext == "ct"))
                .count()
        })
        .unwrap_or(0);
    if ct_count == 0 {
        return Err(format!(
            "no *.ct container produced in {} (CTFS is the only \
             supported materialized-trace format)",
            trace_dir.display()
        ));
    }

    Ok(TestRecording {
        trace_dir,
        source_path: main_py.to_path_buf(),
        binary_path: main_py.to_path_buf(),
        temp_dir: workdir.to_path_buf(),
        language: Language::Python,
        version_label: version_label.to_string(),
    })
}

/// Extract `var_name` as it stands immediately AFTER the breakpoint stop.
///
/// Why this exists: the DAP `request_flow` call uses `FlowMode::Call`, which
/// returns the flow window for the enclosing function call. For top-level
/// Python code, the enclosing "call" is the `<module>` body, so the returned
/// flow contains every loop iteration of the program. `FlowData::values`
/// collapses to the LAST write for each variable across all iterations, which
/// returns the wrong iteration's value for an HCR-style test that breaks at a
/// specific iteration.
///
/// To get the value computed by the assignment AT THE STOP, we:
///   1. Locate the flow step whose `rr_ticks` equals the stop's `rr_ticks`
///      (this is the step at the breakpoint line for the current iteration).
///   2. Walk forward through subsequent steps and return the first
///      `before_values[var_name]` value that *differs from the stop step's
///      before-value* (or is the first populated value if the stop step
///      didn't have one yet). That captures the value of `var_name` once
///      the assignment at the breakpoint has actually executed: the very
///      next step that records `var_name` does so as its `before_values`.
///
/// We must not filter by `iteration` index, because Python's recorder marks
/// steps inside the called `compute()` body with that callee's own loop
/// iteration (effectively 0), which interleaves with the `<module>` loop's
/// iteration tagging. We therefore use the value-changed signal as the
/// primary cue and fall back to the stop step's `after_values` if no later
/// step records the variable.
///
/// JS/Ruby HCR tests don't need this because their recorders produce a
/// per-loop-iteration call key, so `FlowMode::Call` returns just the current
/// iteration's steps and `FlowData::values` already holds the right value.
fn extract_var_value_at_stop(flow: &FlowData, var_name: &str, stop_rr_ticks: i64) -> Option<i64> {
    let stop_idx = flow.steps.iter().position(|s| s.rr_ticks == stop_rr_ticks)?;

    let stop_before = flow.steps[stop_idx]
        .before_values
        .get(var_name)
        .filter(|v| FlowData::is_value_loaded(v))
        .and_then(FlowData::extract_int_value);

    for step in flow.steps.iter().skip(stop_idx + 1) {
        if let Some(v) = step
            .before_values
            .get(var_name)
            .filter(|v| FlowData::is_value_loaded(v))
            .and_then(FlowData::extract_int_value)
        {
            // Skip values that are identical to the stop step's pre-assignment
            // reading — those represent unrelated reads of the still-stale
            // variable before our assignment executes. Once we see a fresh
            // value, we've captured the result of the assignment.
            if Some(v) != stop_before {
                return Some(v);
            }
        }
    }

    // Fallback: `after_values` on the stop step itself (populated by
    // flow_preloader.rs from the next step's `before_values`).
    flow.steps[stop_idx]
        .after_values
        .get(var_name)
        .filter(|v| FlowData::is_value_loaded(v))
        .and_then(FlowData::extract_int_value)
        .or(stop_before)
}

// Notes on Python `FlowMode::Call` semantics
// -----------------------------------------
// The DAP `request_flow` helper requests `FlowMode::Call`, which returns the
// flow window of the enclosing function call. For top-level Python code (the
// `<module>` body), the "call" spans the whole script execution, so the
// returned flow contains all 12 loop iterations of the HCR program.
// `FlowData::values` collapses per-iteration writes by taking the last write
// per variable; for this multi-iteration scope that yields iteration 12's
// value, not the iteration we stopped at.
//
// JavaScript and Ruby HCR tests don't hit this because their recorders bound
// each loop iteration in a way that makes `FlowMode::Call` return only the
// current iteration's steps (Node wraps modules in an implicit function;
// Ruby's `load` cycle similarly bounds the scope).
//
// We work around this on the test side via `extract_var_value_at_stop`,
// which locates the flow step matching the stop's `rr_ticks` and then walks
// forward until it finds a step recording `value` whose reading differs from
// the stop step's stale pre-assignment value. That gives us the value
// computed by the assignment at the stop, regardless of how many other
// iterations the enclosing-call flow includes.
//
// A potential follow-up is to teach `FlowMode::Call` to bound by call key in
// addition to call entry, so loop iterations within `<module>` yield
// independent flow windows. That is out of scope for this test.
#[test]
fn test_python_hcr_ctfs_integration() {
    // -- Guard: skip if the CTFS-emitting recorder or Python 3.10+ unavailable --
    if find_python_recorder().is_none() {
        eprintln!(
            "SKIPPED: CTFS-emitting Python recorder not found \
             (install codetracer_python_recorder or set CODETRACER_PYTHON_RECORDER_PATH)"
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
    let pre_loc_rr_ticks = pre_loc.rr_ticks.0;
    println!(
        "Requesting pre-reload flow data (stop rr_ticks={})...",
        pre_loc_rr_ticks
    );
    let pre_flow = client.request_flow(pre_loc).expect("failed to request pre-reload flow");

    // Verify pre-reload value: compute(3) = 6 (v1: n*2). We use
    // `extract_var_value_at_stop` because the Python `<module>` call key
    // spans all 12 loop iterations (see the module-level note above).
    println!("Pre-reload flow has {} steps", pre_flow.steps.len());
    let pre_value = extract_var_value_at_stop(&pre_flow, "value", pre_loc_rr_ticks).unwrap_or_else(|| {
        panic!(
            "pre-reload: could not locate `value` for stop step rr_ticks={} (variables seen: {:?})",
            pre_loc_rr_ticks, pre_flow.all_variables
        )
    });
    assert_eq!(
        pre_value, PRE_RELOAD_EXPECTED_VALUE,
        "pre-reload: expected value={} (v1: 3*2), got {}",
        PRE_RELOAD_EXPECTED_VALUE, pre_value
    );
    println!("Pre-reload check PASSED: value = {} (v1: 3*2)", pre_value);

    // Cross-check `counter` at the stop: it must equal 3 (1-based iteration 3).
    let pre_counter = pre_flow
        .steps
        .iter()
        .find(|s| s.rr_ticks == pre_loc_rr_ticks)
        .and_then(|s| s.before_values.get("counter"))
        .and_then(FlowData::extract_int_value)
        .unwrap_or_else(|| {
            panic!(
                "pre-reload: stop step {} not found or `counter` missing",
                pre_loc_rr_ticks
            )
        });
    assert_eq!(
        pre_counter, 3,
        "pre-reload: expected counter=3 at stop, got {}",
        pre_counter
    );
    println!("Pre-reload counter cross-check PASSED: counter = 3");

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
    let post_loc_rr_ticks = post_loc.rr_ticks.0;
    println!(
        "Requesting post-reload flow data (stop rr_ticks={})...",
        post_loc_rr_ticks
    );
    let post_flow = client
        .request_flow(post_loc)
        .expect("failed to request post-reload flow");

    // Verify post-reload value: compute(9) = 27 (v2: n*3).
    println!("Post-reload flow has {} steps", post_flow.steps.len());
    let post_value = extract_var_value_at_stop(&post_flow, "value", post_loc_rr_ticks).unwrap_or_else(|| {
        panic!(
            "post-reload: could not locate `value` for stop step rr_ticks={} (variables seen: {:?})",
            post_loc_rr_ticks, post_flow.all_variables
        )
    });
    assert_eq!(
        post_value, POST_RELOAD_EXPECTED_VALUE,
        "post-reload: expected value={} (v2: 9*3), got {}",
        POST_RELOAD_EXPECTED_VALUE, post_value
    );
    println!("Post-reload check PASSED: value = {} (v2: 9*3)", post_value);

    // Cross-check `counter` at the stop: it must equal 9.
    let post_counter = post_flow
        .steps
        .iter()
        .find(|s| s.rr_ticks == post_loc_rr_ticks)
        .and_then(|s| s.before_values.get("counter"))
        .and_then(FlowData::extract_int_value)
        .unwrap_or_else(|| {
            panic!(
                "post-reload: stop step {} not found or `counter` missing",
                post_loc_rr_ticks
            )
        });
    assert_eq!(
        post_counter, 9,
        "post-reload: expected counter=9 at stop, got {}",
        post_counter
    );
    println!("Post-reload counter cross-check PASSED: counter = 9");

    println!("\nPython HCR CTFS integration test completed successfully!");
}
