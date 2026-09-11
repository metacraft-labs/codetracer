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
//!
//! # History: two defects this test found, both now fixed (2026-09-09)
//!
//! **Do not weaken these assertions.** They were made unconditional on purpose
//! and each one caught something real.
//!
//! ## 1. The green that asserted nothing
//!
//! Until 2026-09-09 this test passed in 0.10 s (python: 4.27 s) while checking
//! nothing: it recorded with a *file* entry, so the recorded program died at its
//! first `require` (see [`record_hcr_trace`] for why the entry must be the
//! program DIRECTORY), and both value checks sat behind `if let Some(..)`
//! escape hatches whose bodies never ran. The stop line was never asserted
//! either, so nobody noticed the debugger stopping at `index.js:6` when line 23
//! had been requested.
//!
//! ## 2. The cross-file step mis-attribution it then exposed
//!
//! With the recording fixed the program ran to completion, and the test went
//! red against a genuine `codetracer-js-recorder` defect: **every step recorded
//! outside the first instrumented file was attributed to a line of that first
//! file.**
//!
//! Mechanically: the instrumenter emits `__ct.step(siteId)` / `__ct.enter(fnId)`
//! with the ids as bare numeric literals, and the recorder resolves them by
//! indexing the merged manifest's `sites` / `functions` arrays. But each file
//! was instrumented with its own `ManifestBuilder`, numbering from zero, and
//! `mergeManifestSlices` then concatenated the per-file arrays — renumbering the
//! manifest's internal `fnId` references while the emitted code kept the local
//! ids. So `mymodule.js`'s `__ct.step(21)` resolved against `index.js`'s site
//! 21. In this fixture that is `index.js:23` — the breakpoint line — which is
//! why the debugger stopped on a phantom `index.js:23` step that was really the
//! `mymodule.js` module-body step from the initial `require`.
//!
//! That also explains the control experiment recorded here earlier: editing the
//! `if (counter === 7)` block changed *how many sites* `index.js` contributes,
//! so it moved which wrong line the phantom landed on (19 / 20 / 23) and
//! therefore whether the test noticed — while adding ~90 bytes to each line of
//! the same block moved it not at all, because the mapping was by site INDEX,
//! never by byte offset. The per-path line-length table
//! (`ManifestBuilder.setLineLengths` → `register_path_with_line_lengths`) was
//! never implicated.
//!
//! **The defect was not HCR-specific, and that is the bigger half of the
//! finding.** The mechanism needs only more than one instrumented file — no
//! reload, no overwrite — so *every* multi-file JavaScript recording carried
//! wrong step attribution. Reproduced on a two-file program with no reload at
//! all. This test is where it surfaced, not what it was about.
//!
//! Fixed in `codetracer-js-recorder` by minting manifest ids in the merged
//! numbering at instrumentation time (`InstrumentOptions.idBases` /
//! `nextManifestIdBases`), with the merge now refusing a slice that would land
//! anywhere other than its declared base. Pinned there by
//! `tests/transform/manifest-id-spaces.test.ts`.
//!
//! Measured after the fix (Linux x86_64, 2026-09-09): 169 flow steps at both
//! stops, `value=6`/`counter=3` pre-reload and `value=27`/`counter=9`
//! post-reload. (The 169 was itself wrong — see §3 below; it is 93 now.) The
//! on-disk step stream now shows the initial `require` as five `mymodule.js`
//! steps (lines 1, 3, 8, 13, 18) where it previously showed five `index.js`
//! steps at lines 1, 6, 12, 23, 24.
//!
//! The python and ruby HCR tests never hit this — their recorders emit
//! `(path, line)` per step rather than an index into a merged manifest, so there
//! is no cross-file id space to get wrong. Both are green with the same four
//! assertions (python 112 flow steps, ruby 135).
//!
//! ## 3. Flow-window frame contamination (fixed 2026-09-11)
//!
//! The 169 above was never the clean analogue of python's 112. Only **93** of
//! those steps were `index.js`'s own; the other 76 were `mymodule.js` /
//! `mymodule_v2.js` steps rendered at `index.js` line numbers. The tell was
//! `index.js:13`, reported 24 times for a loop that runs 12 — 12 real
//! `if (counter === 7)` steps plus 12 `mymodule.js:13` (`function aggregate`)
//! steps collapsed onto the same number. Python's flow for the same program
//! shape contained no `mymodule.py` lines at all.
//!
//! This was NOT the id-space defect returning: the container decodes every step
//! to the right path (verified by dumping `steps.dat` against `paths.dat`). The
//! JS recorder emits a function's declaration-line step *before* opening the
//! call — deliberately, so that the trace-format `entryStep` convention's LEAF
//! CLAMP anchors a body-less callee on its own definition line rather than on
//! the caller's call site (see `flow_preloader.rs`'s
//! `step_belongs_to_window_file` for the full convention) — so that step
//! carries the caller's `call_key` while naming the callee's file. In the container
//! `mymodule.js:3` has `call_key=0` (`index.js`'s module frame) while the body
//! step `mymodule.js:5` that follows has `call_key=2`. `ct/load-flow` filtered
//! by `call_key` correctly and was handed mis-framed steps.
//!
//! The missing invariant was that **nothing enforced that a line lies within the
//! file it names**. The nim flow window showed the same class of defect from the
//! other side, with `system.nim` lines 394/398 surfacing inside a 23-line user
//! file. One guard closes both: `flow_preloader.rs`'s
//! `step_belongs_to_window_file`, which walks over a step whose path is not the
//! window's file instead of rendering its line.
//!
//! The count is now asserted, by
//! [`assert_flow_window_is_index_js_only`] — not as a number copied from a
//! recording, but as the per-line histogram `index.js`'s own control flow
//! dictates. **93** steps at both stops.

mod test_harness;

use std::path::PathBuf;
use test_harness::{DapStdioTestClient, FlowData, Language, TestRecording, find_js_recorder};

/// Line number in `index.js` used as the breakpoint target.
///
/// `var value = mymodule.compute(counter);` is on line **22**; we break on
/// line 23 (`var delta = mymodule.transform(value, counter);`) — the first
/// statement *after* the assignment — so that `value` is already bound when
/// the debugger stops and is readable from the stop step's `before_values`.
/// This mirrors `ruby_hcr_ctfs_integration.rs`, which breaks on the line
/// following its own `value = compute(counter)`.
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
/// The program files land in a dedicated `program/` subdirectory rather than
/// at the top of the workdir. That matters: the recorder is driven with the
/// *directory* entry form (see [`record_hcr_trace`]), and it recursively
/// collects every instrumentable file under the entry directory. Keeping the
/// recorder's own output directories (`js-recorder-out/`, `trace/`) as
/// siblings of `program/` rather than inside it keeps them out of that walk.
///
/// Returns `(temp_dir, program_dir)`.
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
    let program_dir = temp_dir.join("program");
    std::fs::create_dir_all(&program_dir).map_err(|e| format!("failed to create temp dir: {}", e))?;

    // Copy all files from the source directory
    for entry in std::fs::read_dir(&src_dir).map_err(|e| format!("failed to read source dir: {}", e))? {
        let entry = entry.map_err(|e| format!("dir entry error: {}", e))?;
        let dest = program_dir.join(entry.file_name());
        std::fs::copy(entry.path(), &dest).map_err(|e| format!("failed to copy {}: {}", entry.path().display(), e))?;
    }

    Ok((temp_dir, program_dir))
}

/// Record the HCR program and return a `TestRecording`.
///
/// We drive the JS recorder manually because the HCR program is a multi-file
/// directory. The JS recorder uses `node <cli> record <entry> --out-dir <dir>`
/// and creates a `trace-N` subdirectory inside the output dir. The recorder
/// selects the trace format itself (CTFS by default after the recorder
/// convention compliance work); ct-side callers must not pass `--format`.
///
/// **The entry must be the program DIRECTORY, not `index.js`.** The recorder
/// instruments the entry into a private staging directory
/// (`$TMPDIR/ct-record-XXXXXX/`) and executes the staged copy from there. With
/// a *file* entry only that one file is staged, so `require("./mymodule")`
/// resolves against the staging directory, finds nothing, and the recorded
/// program dies with `MODULE_NOT_FOUND` at `index.js:6` — yielding a 3-step
/// trace that never reaches the loop. With a *directory* entry the recorder
/// collects and stages every sibling, `index.js` / `mymodule.js` /
/// `mymodule_v2.js` all land in the staging dir, and the reload the fixture
/// performs (`copyFileSync(mymodule_v2.js -> mymodule.js)` + `require.cache`
/// eviction) swaps one instrumented module for another exactly as intended.
fn record_hcr_trace(
    program_dir: &std::path::Path,
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
            program_dir.to_str().unwrap(),
            "--out-dir",
            recorder_out.to_str().unwrap(),
        ])
        .current_dir(workdir)
        .output()
        .map_err(|e| format!("failed to run JavaScript recorder: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();

    if !output.status.success() {
        return Err(format!(
            "JavaScript HCR recording failed:\nstdout: {}\nstderr: {}",
            stdout, stderr
        ));
    }

    // Second, independent check on the same condition. The recorder USED to
    // exit 0 even when the recorded program aborted — it printed
    // `Warning: recorded program exited with code N`, still wrote the truncated
    // trace, and the `status.success()` check above passed. That is how this
    // test reported success for two months against a program that never ran
    // past its first `require`.
    //
    // The recorder now propagates the child's exit code
    // (`Recorder-CLI-Conventions.md` §6), so the check above does catch it. This
    // one stays because it is the only thing that would notice a regression in
    // that propagation — a status check cannot detect its own blind spot.
    let combined = format!("{}{}", stdout, stderr);
    if combined.contains("recorded program exited with code") {
        return Err(format!(
            "the recorded JavaScript program aborted; the trace is truncated and \
             cannot demonstrate HCR:\nstdout: {}\nstderr: {}",
            stdout, stderr
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

    let index_js = program_dir.join("index.js");
    Ok(TestRecording {
        trace_dir,
        source_path: index_js.clone(),
        binary_path: index_js,
        temp_dir: workdir.to_path_buf(),
        language: Language::JavaScript,
        version_label: version_label.to_string(),
    })
}

/// Extract `var_name` as it stands at the breakpoint stop.
///
/// This mirrors `ruby_hcr_ctfs_integration.rs::extract_var_value_at_stop`, and
/// deliberately replaces the old `FlowData::values` lookup. `FlowData::values`
/// collapses to the LAST write of each variable across the whole flow window,
/// so for a 12-iteration loop it answers with iteration 12 regardless of which
/// hit the debugger stopped at — it cannot distinguish pre-reload from
/// post-reload and is therefore useless for this test.
///
/// We anchor on the stop event's `rr_ticks` instead. The breakpoint sits on the
/// statement *after* the `value` assignment, so `value` is already bound on the
/// stop step and `before_values` holds it. The forward walk and the
/// `after_values` fallback cover recorders that publish the assignment result
/// one step later.
fn extract_var_value_at_stop(flow: &FlowData, var_name: &str, stop_rr_ticks: i64) -> Option<i64> {
    let stop_idx = flow.steps.iter().position(|s| s.rr_ticks == stop_rr_ticks)?;

    let stop_before = flow.steps[stop_idx]
        .before_values
        .get(var_name)
        .filter(|v| FlowData::is_value_loaded(v))
        .and_then(FlowData::extract_int_value);
    if stop_before.is_some() {
        return stop_before;
    }

    for step in flow.steps.iter().skip(stop_idx + 1) {
        if let Some(v) = step
            .before_values
            .get(var_name)
            .filter(|v| FlowData::is_value_loaded(v))
            .and_then(FlowData::extract_int_value)
            && Some(v) != stop_before
        {
            return Some(v);
        }
    }

    flow.steps[stop_idx]
        .after_values
        .get(var_name)
        .filter(|v| FlowData::is_value_loaded(v))
        .and_then(FlowData::extract_int_value)
        .or(stop_before)
}

/// The per-line step histogram `index.js`'s own control flow dictates.
///
/// Derived from the fixture source, not from a recording — which is what makes
/// it an assertion rather than a transcript:
///
/// ```text
///    4  var fs = require("fs");                     once
///    5  var path = require("path");                 once
///    6  var mymodule = require("./mymodule");       once
///    8  var counter = 0;                            once
///    9  var history = [];                           once
///   11  for (var i = 0; i < 12; i++) {              once (the loop header's init)
///   12      counter += 1;                           12 iterations
///   13      if (counter === 7) {                    12 iterations
///   15          fs.copyFileSync(                    only when counter === 7
///   19          delete require.cache[...];          only when counter === 7
///   20          mymodule = require("./mymodule");   only when counter === 7
///   22      var value = mymodule.compute(counter);  12 iterations
///   23      var delta = mymodule.transform(...);    12 iterations
///   24      history.push(delta);                    12 iterations
///   25      var total = mymodule.aggregate(...);    12 iterations
///   26      console.log(...);                       12 iterations
/// ```
///
/// Total: 6 + 3 + (7 x 12) = **93**.
const EXPECTED_INDEX_JS_LINE_HISTOGRAM: &[(i64, usize)] = &[
    (4, 1),
    (5, 1),
    (6, 1),
    (8, 1),
    (9, 1),
    (11, 1),
    (12, 12),
    (13, 12),
    (15, 1),
    (19, 1),
    (20, 1),
    (22, 12),
    (23, 12),
    (24, 12),
    (25, 12),
    (26, 12),
];

fn line_histogram(flow: &FlowData) -> std::collections::BTreeMap<i64, usize> {
    let mut hist: std::collections::BTreeMap<i64, usize> = std::collections::BTreeMap::new();
    for step in &flow.steps {
        *hist.entry(step.line).or_default() += 1;
    }
    hist
}

/// Assert that the flow window for `index.js` contains `index.js`'s steps and
/// ONLY `index.js`'s steps.
///
/// # Why this is asserted by histogram rather than by path
///
/// A flow step has no path on the wire: `FlowStep` carries a bare
/// `position` (line number) and the frontend renders it against the window's
/// own file (`src/db-backend/src/task.rs`, `FlowStep`). "Which file did this
/// step come from" is therefore not directly observable from here. The
/// histogram is — and a step from another file cannot enter this window
/// without changing it, because it lands on some `index.js` line number it has
/// no business being on.
///
/// # What it caught
///
/// Before `flow_preloader.rs` gained `step_belongs_to_window_file`, this window
/// reported **169** steps: 93 of `index.js`'s own plus 76 `mymodule.js` /
/// `mymodule_v2.js` steps rendered at `index.js` line numbers. The tell was
/// `index.js:13`, reported **24** times for a loop that runs 12 — the extra 12
/// being `mymodule.js:13`, the declaration line of `aggregate`, which is called
/// once per iteration.
///
/// The recorder emits a callee's declaration-line step immediately BEFORE the
/// `Call` event on purpose — it is what the trace-format `entryStep`
/// convention's leaf clamp falls back to, so a callee with no body step of its
/// own still anchors on its definition line (the convention itself is the
/// "next-step" semantic; see `flow_preloader.rs`'s
/// `step_belongs_to_window_file`). So that step carries the CALLER's `call_key`
/// while naming the CALLEE's file. `ct/load-flow` filtered by `call_key`
/// correctly and was handed mis-framed steps; nothing checked that a line lay
/// within the file it named.
fn assert_flow_window_is_index_js_only(label: &str, flow: &FlowData) {
    let actual = line_histogram(flow);
    let expected: std::collections::BTreeMap<i64, usize> = EXPECTED_INDEX_JS_LINE_HISTOGRAM.iter().copied().collect();
    let expected_total: usize = expected.values().sum();

    assert_eq!(
        actual, expected,
        "{label}: the index.js flow window must contain index.js's steps and only index.js's steps.\n           expected: {expected:?}\n  actual:   {actual:?}\n           A surplus on a line means steps from another file were rendered at index.js line numbers \
         (see assert_flow_window_is_index_js_only); a deficit means real index.js steps were dropped."
    );
    assert_eq!(
        flow.steps.len(),
        expected_total,
        "{label}: the histogram and the step count must agree ({expected_total} steps)"
    );
    println!("{label}: flow window is index.js-only, {expected_total} steps, index.js:13 seen 12 times");
}

#[test]
fn test_javascript_hcr_ctfs_integration() {
    // -- Guard: prerequisite check. Loud, and fatal when CI says so. --
    if find_js_recorder().is_none() {
        test_harness::skip_or_fail_missing_prerequisite(
            "test_javascript_hcr_ctfs_integration",
            "JavaScript recorder not found",
            "set CODETRACER_JS_RECORDER_PATH or build codetracer-js-recorder \
             (cd ../codetracer-js-recorder && just build)",
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
    let (workdir, program_dir) = prepare_hcr_workdir().expect("failed to prepare HCR workdir");
    println!("HCR workdir: {}", workdir.display());

    println!("Recording HCR trace (ctfs)...");
    let recording = record_hcr_trace(&program_dir, &workdir, &version_label).expect("failed to record HCR trace");
    println!("Trace dir: {}", recording.trace_dir.display());

    // -- Start DAP session --
    println!("Starting DAP stdio client...");
    let mut client = DapStdioTestClient::start().expect("failed to start DAP client");

    println!("Initializing DAP session...");
    client
        .initialize_and_launch(&recording)
        .expect("failed to initialize DAP session");

    // The recorder stores the program's real absolute paths in the manifest
    // (`<trace>/files/<abs path>` holds the captured source), so the breakpoint
    // is set on the program-directory copy the recorder actually saw.
    let bp_source = program_dir.join("index.js");

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
    // The breakpoint must actually have been honoured. Without this the test
    // cannot tell "stopped at the requested line" from "ran off the end of a
    // truncated trace and stopped wherever it ended" — which is precisely how
    // this test used to report success against a program that aborted at its
    // first `require`.
    assert_eq!(
        pre_loc.line as u32, COMPUTE_CALL_LINE,
        "pre-reload: breakpoint was requested at index.js:{} but the debugger stopped at {}:{}",
        COMPUTE_CALL_LINE, pre_loc.path, pre_loc.line
    );
    let pre_loc_rr_ticks = pre_loc.rr_ticks.0;
    println!(
        "Requesting pre-reload flow data (stop rr_ticks={})...",
        pre_loc_rr_ticks
    );
    let pre_flow = client.request_flow(pre_loc).expect("failed to request pre-reload flow");

    // Verify pre-reload value: compute(3) = 6 (v1: n*2)
    println!("Pre-reload flow has {} steps", pre_flow.steps.len());
    assert_flow_window_is_index_js_only("pre-reload", &pre_flow);
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
    // This pins the assertion above to the iteration we believe we are on.
    let pre_counter = extract_var_value_at_stop(&pre_flow, "counter", pre_loc_rr_ticks).unwrap_or_else(|| {
        panic!(
            "pre-reload: could not locate `counter` for stop step rr_ticks={} (variables seen: {:?})",
            pre_loc_rr_ticks, pre_flow.all_variables
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
    assert_eq!(
        post_loc.line as u32, COMPUTE_CALL_LINE,
        "post-reload: breakpoint was requested at index.js:{} but the debugger stopped at {}:{}",
        COMPUTE_CALL_LINE, post_loc.path, post_loc.line
    );
    let post_loc_rr_ticks = post_loc.rr_ticks.0;
    println!(
        "Requesting post-reload flow data (stop rr_ticks={})...",
        post_loc_rr_ticks
    );
    let post_flow = client
        .request_flow(post_loc)
        .expect("failed to request post-reload flow");

    // Verify post-reload value: compute(9) = 27 (v2: n*3)
    println!("Post-reload flow has {} steps", post_flow.steps.len());
    assert_flow_window_is_index_js_only("post-reload", &post_flow);
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
    let post_counter = extract_var_value_at_stop(&post_flow, "counter", post_loc_rr_ticks).unwrap_or_else(|| {
        panic!(
            "post-reload: could not locate `counter` for stop step rr_ticks={} (variables seen: {:?})",
            post_loc_rr_ticks, post_flow.all_variables
        )
    });
    assert_eq!(
        post_counter, 9,
        "post-reload: expected counter=9 at stop, got {}",
        post_counter
    );
    println!("Post-reload counter cross-check PASSED: counter = 9");

    // The two values must differ — that difference IS the hot code reload.
    // Equal values would mean the reload never took effect even if both
    // assertions above somehow held.
    assert_ne!(
        pre_value, post_value,
        "the reload had no observable effect: pre-reload and post-reload `value` are both {}",
        pre_value
    );

    println!("\nJavaScript HCR CTFS integration test completed successfully!");
}
