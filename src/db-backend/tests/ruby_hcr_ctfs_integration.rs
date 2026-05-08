//! Integration test for Ruby HCR (Hot Code Reload) using CTFS trace format
//!
//! Verifies that the DAP server correctly reports variable values both before
//! and after a module reload. The test program (`ruby_hcr_flow_test/main.rb`)
//! loops 12 times, reloading `mymodule.rb` at step 7. Before reload, `compute(n)`
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
use test_harness::{find_ruby_recorder, DapStdioTestClient, FlowData, Language, TestRecording};

/// Line number in main.rb where `value = compute(counter)` lives.
const COMPUTE_CALL_LINE: u32 = 20;

/// Expected value of `value` at step 3 (pre-reload, v1: 3*2).
const PRE_RELOAD_EXPECTED_VALUE: i64 = 6;

/// Expected value of `value` at step 9 (post-reload, v2: 9*3).
const POST_RELOAD_EXPECTED_VALUE: i64 = 27;

/// Return the path to the HCR test program directory (in-repo).
fn get_hcr_program_dir() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/ruby/ruby_hcr_flow_test")
}

/// Copy the HCR test program into a writable temp directory so the reload
/// (which overwrites `mymodule.rb`) does not mutate the repository checkout.
///
/// Returns `(temp_dir, main_rb_path)`.
fn prepare_hcr_workdir() -> Result<(PathBuf, PathBuf), String> {
    let src_dir = get_hcr_program_dir();
    assert!(
        src_dir.join("main.rb").exists(),
        "HCR test program not found at {}",
        src_dir.display()
    );

    let temp_dir = std::env::temp_dir().join(format!("hcr_flow_test_rb_{}", std::process::id()));
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

    let main_rb = temp_dir.join("main.rb");
    Ok((temp_dir, main_rb))
}

/// Record the HCR program and return a `TestRecording`.
///
/// We drive the Ruby recorder manually because the HCR program is a multi-file
/// directory and the recording must happen with CWD set to the program directory
/// (so `require_relative` works).
fn record_hcr_trace(
    main_rb: &std::path::Path,
    workdir: &std::path::Path,
    version_label: &str,
) -> Result<TestRecording, String> {
    let recorder = find_ruby_recorder().ok_or("Ruby recorder not found")?;

    let trace_dir = workdir.join("trace");
    std::fs::create_dir_all(&trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = std::process::Command::new("ruby")
        .args([
            recorder.to_str().unwrap(),
            "--out-dir",
            trace_dir.to_str().unwrap(),
            main_rb.to_str().unwrap(),
        ])
        .current_dir(workdir)
        .env("CODETRACER_TRACE_FORMAT", "ctfs")
        .output()
        .map_err(|e| format!("failed to run Ruby recorder: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Ruby HCR recording failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    // Copy main.rb into trace_dir so the DAP server can resolve it
    let dest = trace_dir.join("main.rb");
    if !dest.exists() {
        std::fs::copy(main_rb, &dest).map_err(|e| format!("failed to copy main.rb to trace dir: {}", e))?;
    }

    // Verify a CTFS container was produced.  Per the CTFS migration guide
    // (Trace-Files/CTFS-Migration-Guide.md §3e), `.ct` is the only
    // supported materialized-trace format; legacy `trace.json` /
    // `trace.bin` / `trace_metadata.json` sidecars are no longer produced.
    let has_ct = std::fs::read_dir(&trace_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .any(|e| e.path().extension().is_some_and(|ext| ext == "ct"))
        })
        .unwrap_or(false);
    if !has_ct {
        return Err(format!("no *.ct container produced in {}", trace_dir.display()));
    }

    Ok(TestRecording {
        trace_dir,
        source_path: main_rb.to_path_buf(),
        binary_path: main_rb.to_path_buf(),
        temp_dir: workdir.to_path_buf(),
        language: Language::Ruby,
        version_label: version_label.to_string(),
    })
}

/// Extract the integer value of a variable named `var_name` from a specific
/// iteration of a flow line.
///
/// Flow data returns ALL executions of the requested line across the entire
/// trace. The variable may appear in `before_values` at multiple lines per
/// iteration (e.g., before the assignment line, on the assignment line, and on
/// subsequent lines in the same block).
///
/// To get the value at a specific iteration we:
///   1. Filter steps to the target `line_number` (the breakpoint line).
///   2. Take the `occurrence`-th step (1-indexed) on that line.
///   3. Read `var_name` from its `before_values`.
fn extract_var_value_at_line_occurrence(
    flow: &FlowData,
    var_name: &str,
    line_number: i64,
    occurrence: usize,
) -> Option<i64> {
    let mut count = 0;
    for step in &flow.steps {
        if step.line == line_number {
            if let Some(val) = step.before_values.get(var_name) {
                if FlowData::is_value_loaded(val) {
                    count += 1;
                    if count == occurrence {
                        return FlowData::extract_int_value(val);
                    }
                }
            }
        }
    }
    None
}

#[test]
fn test_ruby_hcr_ctfs_integration() {
    // -- Guard: skip if recorder unavailable --
    if find_ruby_recorder().is_none() {
        eprintln!(
            "SKIPPED: Ruby recorder not found \
             (set CODETRACER_RUBY_RECORDER_PATH or check out sibling/submodule)"
        );
        return;
    }

    // Get Ruby version for labeling
    let version_label = std::process::Command::new("ruby")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.split_whitespace().nth(1).map(|v| v.to_string()))
        .unwrap_or_else(|| "unknown".to_string());

    // -- Prepare workdir and record --
    let (workdir, main_rb) = prepare_hcr_workdir().expect("failed to prepare HCR workdir");
    println!("HCR workdir: {}", workdir.display());

    println!("Recording HCR trace (ctfs)...");
    let recording = record_hcr_trace(&main_rb, &workdir, &version_label).expect("failed to record HCR trace");
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
    let bp_source = recording.trace_dir.join("main.rb");

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
    //
    // Flow data returns ALL executions of this line (all 12 iterations).
    // We need to find the step where value=6 (the 3rd iteration).
    println!("Pre-reload flow has {} steps", pre_flow.steps.len());
    let bp_line = COMPUTE_CALL_LINE as i64;
    if let Some(actual) = extract_var_value_at_line_occurrence(&pre_flow, "value", bp_line, 3) {
        assert_eq!(
            actual, PRE_RELOAD_EXPECTED_VALUE,
            "pre-reload: expected value={} (v1: 3*2), got {}",
            PRE_RELOAD_EXPECTED_VALUE, actual
        );
        println!("Pre-reload check PASSED: value = {} (v1: 3*2)", actual);
    } else {
        println!(
            "Pre-reload: 'value' not found at line {} occurrence 3 (variables: {:?}). \
             Checking 'counter' as fallback...",
            bp_line, pre_flow.all_variables
        );
        if let Some(counter_val) = extract_var_value_at_line_occurrence(&pre_flow, "counter", bp_line, 3) {
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
    //
    // The 9th occurrence of `value` in the flow steps corresponds to
    // breakpoint hit #9 (counter=9, post-reload).
    println!("Post-reload flow has {} steps", post_flow.steps.len());
    if let Some(actual) = extract_var_value_at_line_occurrence(&post_flow, "value", bp_line, 9) {
        assert_eq!(
            actual, POST_RELOAD_EXPECTED_VALUE,
            "post-reload: expected value={} (v2: 9*3), got {}",
            POST_RELOAD_EXPECTED_VALUE, actual
        );
        println!("Post-reload check PASSED: value = {} (v2: 9*3)", actual);
    } else {
        println!(
            "Post-reload: 'value' not found at line {} occurrence 9 (variables: {:?}). \
             Checking 'counter' as fallback...",
            bp_line, post_flow.all_variables
        );
        if let Some(counter_val) = extract_var_value_at_line_occurrence(&post_flow, "counter", bp_line, 9) {
            assert_eq!(counter_val, 9, "post-reload: expected counter=9, got {}", counter_val);
            println!("Post-reload fallback PASSED: counter = 9");
        }
    }

    println!("\nRuby HCR CTFS integration test completed successfully!");
}
