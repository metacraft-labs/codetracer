//! Regression test for the GLI byte-offset decode bug surfaced in the
//! cairo and EVM CI runs.
//!
//! Before the fix, the codetracer DAP server's CTFS reader path
//! (`ctfs_trace_reader::open_new_format_nim`) trusted the trace's
//! `meta.hasColumnAwareSteps` bit and called the Nim FFI's
//! `step_locations_with_columns`.  When the recorder (cairo / evm /
//! move) wrote per-line Layout A `paths.dat` data + `global_position_
//! index` byte-offset step encoding but failed to flip the meta bit at
//! close time, the FFI fell back to interpreting raw byte-offset GLIs
//! as `(file_id, line)` via `gli.resolve(...)` — producing absurd
//! "line" numbers (line 270 for a 12-line source).
//!
//! The fix is two-fold:
//!
//! * Nim reader: detect Layout A `paths.dat` data even when meta bit 4
//!   is unset and promote `hasColumnAwareSteps = true` in-memory so the
//!   downstream decode paths see the trace as it was actually written.
//! * Rust dap-server CTFS reader: bypass the Nim FFI's column-aware
//!   decode and use the pure-Rust `GlobalPositionDecoder` directly,
//!   harvesting per-file line lengths via the new ungated `lineLengthRaw`
//!   FFI.
//!
//! This test opens the canonical cairo fixture
//! (`flow_test.ct`, 12-line source) and asserts that every step's
//! `(line, column)` falls inside the source file's addressable range.
//! A regression would surface as `line > 12` (the GLI byte offset
//! escaping the decoder).

#![cfg(feature = "nim-reader")]

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use std::path::PathBuf;

fn cairo_fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../codetracer-vscode-extension/test/traces/cairo-flow-test/flow_test.ct")
}

#[test]
fn cairo_flow_test_lines_stay_within_source_range() {
    let path = cairo_fixture_path();
    if !path.exists() {
        // The fixture is checked into a sibling repo that may not be
        // present in every developer's checkout.  Skip cleanly rather
        // than failing — CI always has the sibling layout.
        eprintln!(
            "skipping cairo_flow_test_lines_stay_within_source_range: fixture missing at {}",
            path.display()
        );
        return;
    }
    let reader = CTFSTraceReader::open(&path).unwrap_or_else(|e| panic!("CTFSTraceReader::open: {e}"));
    let db = reader.db();

    // `flow_test.cairo` is the 12-line source compiled into the fixture
    // — see `codetracer-cairo-recorder/test-programs/cairo/flow_test.cairo`.
    // Lines must stay within `[1, 12]` post-decode; columns within `[1, ~100]`
    // (Cairo source columns are typically < 80, with a generous ceiling
    // to cover formatter-introduced whitespace).
    const MAX_LINE: i64 = 12;
    const MAX_COLUMN: i64 = 256;

    let mut max_seen_line: i64 = 0;
    let mut max_seen_column: i64 = 0;
    for (i, step) in db.steps.iter().enumerate() {
        let line = step.line.0;
        assert!(
            (0..=MAX_LINE).contains(&line),
            "step {}: line {} out of range [0, {}] — GLI byte-offset escaping the decoder?",
            i,
            line,
            MAX_LINE,
        );
        if line > max_seen_line {
            max_seen_line = line;
        }
        if let Some(col) = step.column {
            let col_val = col.0;
            assert!(
                (1..=MAX_COLUMN).contains(&col_val),
                "step {}: column {} out of range [1, {}]",
                i,
                col_val,
                MAX_COLUMN,
            );
            if col_val > max_seen_column {
                max_seen_column = col_val;
            }
        }
    }
    // The fixture exercises lines 1, 2, 3, 4, 5, 6, 7, 10, 11 — so
    // assert at least two distinct lines were visited (defensive against
    // a regression that collapses all steps to a single line).
    let mut unique_lines = std::collections::HashSet::new();
    for step in db.steps.iter() {
        unique_lines.insert(step.line.0);
    }
    assert!(
        unique_lines.len() >= 2,
        "expected at least 2 distinct lines in cairo fixture, saw {}",
        unique_lines.len()
    );
    eprintln!(
        "cairo fixture decoded cleanly: max_line={}, max_column={}, unique_lines={}",
        max_seen_line,
        max_seen_column,
        unique_lines.len()
    );
}
