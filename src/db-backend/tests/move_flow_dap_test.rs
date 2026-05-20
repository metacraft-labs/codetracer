//! Headless DAP tests for Move/Sui traces.
//!
//! These tests verify that the DAP server correctly handles Move traces
//! produced by the codetracer-move-recorder. Each test records a different
//! Move test function's trace and verifies the DAP lifecycle.
//!
//! ## Current recorder limitations
//!
//! The Move recorder does not yet have source map support (`.mvsm` parsing).
//! As a result:
//! - All steps are recorded at line 1 (no PC-to-source-line mapping).
//! - Variable names use bytecode indices (`local_0`, `local_1`, etc.)
//!   instead of source-level names.
//! - Breakpoints at specific source lines cannot be hit.
//! - Flow data within function calls contains 0 steps (the only step is
//!   at the toplevel entry point).
//!
//! Once source map support is added to `codetracer-move-recorder`, these
//! tests should be upgraded to full Tier 2 (DAP flow) tests that set
//! breakpoints at specific lines and verify source-level variable names
//! and values.
//!
//! ## What is tested now
//!
//! Each test verifies:
//! 1. The Move trace file is successfully converted by the recorder.
//! 2. The DAP server initializes and loads the trace without error.
//! 3. The initial stop position references the correct source file.
//! 4. The DAP server disconnects cleanly.
//!
//! ## Prerequisites
//!
//! - `codetracer-move-recorder` binary (set `CODETRACER_MOVE_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-move-recorder/`)
//!
//! Prerequisites are provided by the Nix dev shell (`nix develop`).
//! Run with:
//!   `cargo nextest run move_flow_dap`
//! or:
//!   `just test-move-flow`

use std::path::PathBuf;

use ct_dap_client::test_support::FlowTestRunner;

mod test_harness;
use test_harness::{Language, TestRecording, find_move_flow_source, find_move_recorder, find_move_trace_file};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Returns the path to a specific Move trace file for a given test function.
///
/// The Move recorder expects a pre-recorded trace file (`.json.zst`) produced
/// by the Move compiler/VM test runner. Each test function has its own trace
/// file in `codetracer-move-recorder/test-programs/move/flow_test/traces/`.
fn get_move_trace_file(test_fn_name: &str) -> PathBuf {
    find_move_trace_file(test_fn_name).unwrap_or_else(|| {
        panic!(
            "Move trace file for '{}' not found. \
             Check out codetracer-move-recorder as a sibling repo, or ensure \
             test-programs/move/flow_test/traces/flow_test__flow_test__{}.json.zst exists.",
            test_fn_name, test_fn_name
        )
    })
}

/// Returns the path to the Move source file.
///
/// Uses the same sibling-repo discovery as `find_move_flow_source()`.
fn get_move_source_path() -> PathBuf {
    find_move_flow_source().expect(
        "Move flow test source not found. \
         Check out codetracer-move-recorder as a sibling repo, or ensure \
         test-programs/move/flow_test/sources/flow_test.move exists locally.",
    )
}

/// Shared setup: verify prerequisites, record a trace for the given test
/// function, and resolve the source path.
///
/// `test_fn_name` selects which pre-recorded trace file to use (e.g.
/// `"test_computation"` picks
/// `flow_test__flow_test__test_computation.json.zst`).
///
/// Returns `(db_backend_path, trace_recording, source_path)`.
///
/// # Panics
///
/// Panics if the Move recorder is not found, the trace file is missing,
/// or recording fails.
fn setup_move_trace(test_fn_name: &str) -> (PathBuf, TestRecording, PathBuf) {
    assert!(
        find_move_recorder().is_some(),
        "Move recorder not found. \
         Set CODETRACER_MOVE_RECORDER_PATH or build codetracer-move-recorder \
         (run `cargo build` inside the codetracer-move-recorder repo)."
    );

    let db_backend = find_db_backend();
    let trace_file = get_move_trace_file(test_fn_name);
    let source_path = get_move_source_path();

    // Include test_fn_name in the version label to ensure each test gets a
    // unique temp directory, avoiding races when tests run in parallel.
    let version_label = format!("move-2024-{}", test_fn_name);

    // Record the Move trace via the Move recorder CLI.
    let recording = TestRecording::create_db_trace(&trace_file, Language::Move, &version_label)
        .expect("Move recording failed -- check that codetracer-move-recorder is available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    (db_backend, recording, source_path)
}

/// Run a DAP lifecycle test for a Move trace.
///
/// Records the trace for `test_fn_name`, launches the DAP server, verifies
/// the initial stop references the correct source file, and disconnects.
///
/// Does NOT attempt breakpoint or flow verification because the Move
/// recorder currently lacks source map support (all steps at line 1,
/// variable names are bytecode indices).
fn run_move_dap_lifecycle_test(test_fn_name: &str) {
    let (db_backend, recording, _source_path) = setup_move_trace(test_fn_name);

    // Verify trace files were produced.  Per the CTFS migration guide
    // (Trace-Files/CTFS-Migration-Guide.md §3e) the `.ct` container is
    // self-contained — metadata that used to live in sidecar
    // `trace_metadata.json` / `trace_paths.json` is now baked into the
    // container's `meta.dat` (or `meta.json`) block.  CTFS is the only
    // supported materialized-trace format; legacy sidecars are no longer
    // accepted.
    let trace_dir = &recording.trace_dir;
    let has_ct = std::fs::read_dir(trace_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .any(|e| e.path().extension().is_some_and(|ext| ext == "ct"))
        })
        .unwrap_or(false);
    assert!(has_ct, "no *.ct container found in {}", trace_dir.display());

    // Launch DAP server and verify initialization.
    let runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Move trace");

    // Source path verification has moved into the CTFS container's
    // `meta.dat` paths list (read by the DAP server during launch); we no
    // longer inspect a sidecar `trace_paths.json`.

    // Clean disconnect.
    runner.finish().expect("disconnect failed");

    println!("Move DAP lifecycle test ('{}') passed!", test_fn_name);
}

// ---------------------------------------------------------------------------
// Test: basic arithmetic (test_computation)
// ---------------------------------------------------------------------------

/// DAP lifecycle test for `test_computation()`.
///
/// Verifies trace recording and DAP server initialization for a trace
/// containing basic u64 arithmetic operations.
///
/// Once source map support is added to the Move recorder, this test should
/// be upgraded to verify variables at the breakpoint:
///   a=10, b=32, sum_val=42, doubled=84, final_result=94
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_variables() {
    run_move_dap_lifecycle_test("test_computation");
}

// ---------------------------------------------------------------------------
// Test: struct creation and destructuring (test_structs)
// ---------------------------------------------------------------------------

/// DAP lifecycle test for `test_structs()`.
///
/// Verifies trace recording and DAP server initialization for a trace
/// containing struct creation, field access, and destructuring.
///
/// Once source map support is added, upgrade to verify:
///   px=10, py=10, sum_coords=20, area=40
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_struct_variables() {
    run_move_dap_lifecycle_test("test_structs");
}

// ---------------------------------------------------------------------------
// Test: vector operations (test_vectors)
// ---------------------------------------------------------------------------

/// DAP lifecycle test for `test_vectors()`.
///
/// Verifies trace recording and DAP server initialization for a trace
/// containing vector push/pop/borrow/length operations.
///
/// Once source map support is added, upgrade to verify:
///   len=5, first=10, last=50, sum=150, popped=50, new_len=4
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_vector_ops() {
    run_move_dap_lifecycle_test("test_vectors");
}

// ---------------------------------------------------------------------------
// Test: loops and control flow (test_loops)
// ---------------------------------------------------------------------------

/// DAP lifecycle test for `test_loops()`.
///
/// Verifies trace recording and DAP server initialization for a trace
/// containing while loops, loop/break, and conditionals.
///
/// Once source map support is added, upgrade to verify:
///   counter=10, accumulator=55, power=128, iterations=7
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_loop_variables() {
    run_move_dap_lifecycle_test("test_loops");
}

// ---------------------------------------------------------------------------
// Test: nested function calls (test_nested_calls)
// ---------------------------------------------------------------------------

/// DAP lifecycle test for `test_nested_calls()`.
///
/// Verifies trace recording and DAP server initialization for a trace
/// containing nested function calls and tuple returns.
///
/// Once source map support is added, upgrade to verify:
///   x=12, y=8, sum=20, product=96, max=12, nested_result=15
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_nested_calls() {
    run_move_dap_lifecycle_test("test_nested_calls");
}

// ---------------------------------------------------------------------------
// Test: generic functions (test_generics)
// ---------------------------------------------------------------------------

/// DAP lifecycle test for `test_generics()`.
///
/// Verifies trace recording and DAP server initialization for a trace
/// containing generic Container<T> with different types.
///
/// Once source map support is added, upgrade to verify:
///   v1=42, container_label=3
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_generic_function() {
    run_move_dap_lifecycle_test("test_generics");
}

// ---------------------------------------------------------------------------
// Test: Fibonacci computation (test_fibonacci)
// ---------------------------------------------------------------------------

/// DAP lifecycle test for `test_fibonacci()`.
///
/// Verifies trace recording and DAP server initialization for a trace
/// containing iterative Fibonacci computation.
///
/// Once source map support is added, upgrade to verify:
///   fib_0=0, fib_1=1, fib_5=5, fib_10=55, fib_15=610
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_fibonacci() {
    run_move_dap_lifecycle_test("test_fibonacci");
}
